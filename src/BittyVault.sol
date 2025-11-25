// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Trust} from "./Trust.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {ITrust} from "./interfaces/ITrust.sol";
import {IBeneficiary} from "./interfaces/IBeneficiary.sol";
import {IAaveV3} from "./libs/Aave.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {IYieldProvider} from "./interfaces/IAssetManager.sol";
import {IUniswapV4Router04} from "./libs/Uniswap.sol";
import {AssetManager} from "./AssetManager.sol";
import {IAssetManager} from "./interfaces/IAssetManager.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IMigrator} from "./interfaces/IMigrator.sol";
import {
    AddressZero,
    AlreadyInitialized,
    TransferFailed,
    WETHNotSet,
    InsufficientStablecoinBalance,
    NotWhiteListed
} from "./interfaces/Errors.sol";

/**
 * @title BittyVault
 * @notice Unified vault contract that combines Asset Management and Trust Management
 * @dev
 * This contract inherits from both AssetManager and Trust, providing a single interface
 * for both asset management operations (supply, withdraw, rebalance, etc.) and trust
 * management operations (initialize, revoke, set beneficiaries, etc.).
 *
 * Users can use this contract for asset management only, trust management only, or both.
 * The contract address remains the same regardless of which functions are used.
 * All asset management functions are defined in AssetManager.sol
 * All trust management functions are defined in Trust.sol (which implements ITrust)
 * This contract only handles:
 * 1. Resolving inheritance conflicts (modifiers, abstract functions)
 * 2. Bridging between the two modules (usdt/usdc functions for Trust.getMoney)
 */
contract BittyVault is Trust, AssetManager, IVault {
    using EnumerableSet for EnumerableSet.AddressSet;

    IMigrator public override migrator;

    // Full initialize with all parameters (used by factory)
    function initialize(
        address grantorAddress,
        address wethAddress,
        address whiteListAddress,
        address migratorAddress,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory yieldProviders,
        address[] memory swapProviders
    ) external initializer {
        AssetManager._initialize(
            wethAddress, whiteListAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders
        );
        if (migratorAddress == address(0)) {
            revert AddressZero();
        }
        migrator = IMigrator(migratorAddress);
        if (grantorAddress == address(0)) {
            revert AddressZero();
        }
        grantor = grantorAddress;
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        isInitialized = true;
    }

    function migrate() external onlyInitialized onlyTrustee {
        address nextVault = migrator.nextVault(address(this));
        if (nextVault == address(0)) {
            revert AddressZero();
        }
        _revoke(nextVault);
    }

    /**
     * @notice Override revoke to transfer all assets to the grantor
     * @dev Transfers all assets (USDT, USDC, WBTC, WETH, ETH) and withdraws from Aave if needed
     */
    function revoke(address moneyWithdrawTo) external override onlyInitialized onlyGrantor onlyRevocable {
        _revoke(moneyWithdrawTo);
    }

    function _revoke(address moneyWithdrawTo) internal {
        if (moneyWithdrawTo == address(0)) {
            revert AddressZero();
        }
        for (uint256 i = 0; i < _assets.length(); i++) {
            _transferAllERC20(_assets.at(i), moneyWithdrawTo);
        }

        for (uint256 i = 0; i < _stableCoins.length(); i++) {
            _transferAllERC20(_stableCoins.at(i), moneyWithdrawTo);
        }

        // Transfer any remaining ETH
        if (address(this).balance > 0) {
            (bool success,) = payable(moneyWithdrawTo).call{value: address(this).balance}("");
            if (!success) {
                revert TransferFailed();
            }
        }
    }

    /**
     * @notice Internal function to transfer all balance of an ERC20 token
     */
    function _transferAllERC20(address tokenAddress, address to) internal {
        if (tokenAddress == address(0)) {
            return;
        }
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            if (!token.transfer(to, balance)) {
                revert TransferFailed();
            }
        }
    }

    function supply(address yieldProvider, address assetAddress, uint256 amount)
        external
        onlyInitialized
        onlyAssetManager
    {
        _supply(yieldProvider, assetAddress, amount);
    }

    function withdraw(address yieldProvider, address assetAddress, uint256 amount)
        external
        onlyInitialized
        onlyAssetManager
    {
        _withdraw(yieldProvider, assetAddress, amount);
    }

    function rebalance(
        address swapProvider,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes calldata data
    ) external onlyInitialized onlyAssetManager {
        _rebalance(swapProvider, from, to, sellAmount, buyAmountMin, data);
    }

    function turnETHToWETH() external onlyInitialized {
        if (wethAddress == address(0)) {
            revert WETHNotSet();
        }
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            WETH(payable(wethAddress)).deposit{value: ethBalance}();
        }
    }

    function setRebalanceRules(RebalanceLimit memory rebalanceLimit) external onlyInitialized onlyTrustee {
        _setRebalanceRules(rebalanceLimit);
    }

    /**
     * @notice Override _getMoney to use internal EnumerableSets
     * @dev Transfers stablecoin amount to beneficiary, trying each stablecoin until one has sufficient balance
     */
    function _getMoney(uint256 amount, address stableCoinAddress, address to) internal override {
        uint256 withdrawAmountDecimals = amount * 10 ** ERC20(stableCoinAddress).decimals();
        IERC20 stableCoin = IERC20(stableCoinAddress);
        uint256 balance = stableCoin.balanceOf(address(this));
        if (balance >= withdrawAmountDecimals) {
            if (!stableCoin.transfer(to, withdrawAmountDecimals)) {
                revert TransferFailed();
            }
            return;
        }
        uint256 yieldWithdrawAmount = withdrawAmountDecimals - balance;
        bool withdrawEnough = false;
        for (uint256 i = 0; i < _yieldProviders.length(); i++) {
            address yieldProvider = _yieldProviders.at(i);
            uint256 yieldProviderBalance = IYieldProvider(yieldProvider).getBalance(stableCoinAddress);
            if (yieldProviderBalance == 0) {
                continue;
            }
            withdrawEnough = yieldProviderBalance >= yieldWithdrawAmount;
            uint256 withdrawAmount = withdrawEnough ? yieldWithdrawAmount : yieldProviderBalance;
            IYieldProvider(yieldProvider).withdraw(stableCoinAddress, withdrawAmount);
            if (!withdrawEnough) {
                yieldWithdrawAmount -= withdrawAmount;
            }
            if (withdrawEnough) {
                break;
            }
        }
        if (!withdrawEnough) {
            revert InsufficientStablecoinBalance();
        }
        if (!stableCoin.transfer(to, withdrawAmountDecimals)) {
            revert TransferFailed();
        }
    }

    /**
     * @notice Override _getPercentageMoney to use internal EnumerableSets
     * @dev Transfers percentage of all stablecoins and assets to beneficiary
     */
    function _getPercentageMoney(uint256 percentage, address to) internal override {
        // Transfer percentage from all stablecoins
        uint256 stableCoinsLength = _stableCoins.length();
        for (uint256 i = 0; i < stableCoinsLength; i++) {
            address stableCoinAddress = _stableCoins.at(i);
            IERC20 stableCoin = IERC20(stableCoinAddress);
            uint256 balance = stableCoin.balanceOf(address(this));
            uint256 amount = balance * percentage / 10000;
            if (amount > 0) {
                if (!stableCoin.transfer(to, amount)) {
                    revert TransferFailed();
                }
            }
        }

        // Transfer percentage from all assets
        uint256 assetsLength = _assets.length();
        for (uint256 i = 0; i < assetsLength; i++) {
            address assetAddress = _assets.at(i);
            IERC20 asset = IERC20(assetAddress);
            uint256 balance = asset.balanceOf(address(this));
            uint256 amount = balance * percentage / 10000;
            if (amount > 0) {
                if (!asset.transfer(to, amount)) {
                    revert TransferFailed();
                }
            }
        }
    }

    function setAssetConfig(address assetAddress, IAssetManager.AssetConfig memory assetConfig)
        external
        onlyInitialized
        onlyTrustee
    {
        _setAssetConfig(assetAddress, assetConfig);
    }

    function addAssets(address[] memory assetAddresses) external onlyInitialized onlyTrustee {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (!whiteList.isAssetWhiteListed(assetAddresses[i])) {
                revert NotWhiteListed();
            }
            _assets.add(assetAddresses[i]);
        }
    }

    function removeAssets(address[] memory assetAddresses) external onlyInitialized onlyTrustee {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            _assets.remove(assetAddresses[i]);
        }
    }

    function addStableCoins(address[] memory stableCoinAddresses) external onlyInitialized onlyTrustee {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (!whiteList.isStableCoinWhiteListed(stableCoinAddresses[i])) {
                revert NotWhiteListed();
            }
            _stableCoins.add(stableCoinAddresses[i]);
        }
    }

    function removeStableCoins(address[] memory stableCoinAddresses) external onlyInitialized onlyTrustee {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            _stableCoins.remove(stableCoinAddresses[i]);
        }
    }

    function addYieldProviders(address[] memory yieldProviderAddresses) external onlyInitialized onlyTrustee {
        for (uint256 i = 0; i < yieldProviderAddresses.length; i++) {
            if (!whiteList.isYieldProviderWhiteListed(yieldProviderAddresses[i])) {
                revert NotWhiteListed();
            }
            _yieldProviders.add(yieldProviderAddresses[i]);
        }
    }

    function removeYieldProviders(address[] memory yieldProviderAddresses) external onlyInitialized onlyTrustee {
        for (uint256 i = 0; i < yieldProviderAddresses.length; i++) {
            _yieldProviders.remove(yieldProviderAddresses[i]);
        }
    }

    function addSwapProviders(address[] memory swapProviderAddresses) external onlyInitialized onlyTrustee {
        for (uint256 i = 0; i < swapProviderAddresses.length; i++) {
            if (!whiteList.isSwapProviderWhiteListed(swapProviderAddresses[i])) {
                revert NotWhiteListed();
            }
            _swapProviders[swapProviderAddresses[i]] = true;
        }
    }

    function removeSwapProviders(address[] memory swapProviderAddresses) external onlyInitialized onlyTrustee {
        for (uint256 i = 0; i < swapProviderAddresses.length; i++) {
            _swapProviders[swapProviderAddresses[i]] = false;
        }
    }

    // All trust management functions are inherited from Trust:
    // - initialize, initaialize (multiple overloads)
    // - revoke, setToIrrevocable
    // - ping, setAutoIrrevocableAfterNoPing
    // - setGrantor, setTrustee, setBeneficiary
    // - setBeneficiarySettings, getMoney
    // - changeBeneficiaryAddress, changeTrusteeAddress
    // - setStartDistributionTimestamp, distributionStarted
    // - upgrade
}
