// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Trust} from "./Trust.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {IYieldProvider, ISwapProvider} from "./interfaces/IAssetManager.sol";
import {IUniswapV4Router04} from "./libs/Uniswap.sol";
import {OracleLibrary} from "./libs/OracleLibrary.sol";
import {IPoolManager, PoolKey, PoolIdLibrary} from "./libs/Uniswap.sol";
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
import {VaultHelper} from "./helpers/VaultHelper.sol";

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

    address public override migrator;
    uint256 public immutable override version = 1;
    IPoolManager public poolManager;

    // Full initialize with all parameters (used by factory)
    function initialize(
        address grantorAddress,
        address wethAddress,
        address poolManagerAddress,
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
        migrator = migratorAddress;
        poolManager = IPoolManager(poolManagerAddress);
        grantor = grantorAddress;
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        isInitialized = true;
    }

    function initialize(address, bytes memory) external pure override {
        revert AlreadyInitialized();
    }

    function createAndMigrate(uint256 _toVersion, string calldata _salt)
        external
        override
        onlyInitialized
        onlyTrustee
        returns (address)
    {
        address nextVault = IMigrator(migrator).createVersionVault(address(this), _toVersion, _salt);
        if (nextVault == address(0)) {
            revert AddressZero();
        }
        _revoke(nextVault);
        return nextVault;
    }

    function migrateAssets(uint256 _toVersion) external override onlyInitialized onlyTrustee {
        address nextVault = IMigrator(migrator).versionVault(address(this), _toVersion);
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
     * @notice Override _getMoney to use library implementation
     * @dev Transfers stablecoin amount to beneficiary
     * if the stablecoin balance is not enough, get from yield providers and swap assets until enough
     */
    function _getMoney(uint256 amount, address stableCoinAddress, address to) internal override {
        VaultHelper.getMoney(
            address(this),
            poolManager,
            _yieldProviders.values(),
            _swapProviders.values(),
            _assets.values(),
            amount,
            stableCoinAddress,
            to
        );
    }

    /**
     * @notice Override _getPercentageMoney to use library implementation
     * @dev Transfers percentage of all stablecoins and assets to beneficiary
     */
    function _getPercentageMoney(uint256 percentage, address to) internal override {
        VaultHelper.getPercentageMoney(address(this), _stableCoins.values(), _assets.values(), percentage, to);
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
            _swapProviders.add(swapProviderAddresses[i]);
        }
    }

    function removeSwapProviders(address[] memory swapProviderAddresses) external onlyInitialized onlyTrustee {
        for (uint256 i = 0; i < swapProviderAddresses.length; i++) {
            _swapProviders.remove(swapProviderAddresses[i]);
        }
    }
}
