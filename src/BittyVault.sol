// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Trust} from "./Trust.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ITrust} from "./interfaces/ITrust.sol";
import {IAaveV3} from "./libs/Aave.sol";
import {IUniswapV4Router04} from "./libs/Uniswap.sol";
import {AssetManager} from "./AssetManager.sol";
import {AddressZero, AlreadyInitialized, TransferFailed} from "./interfaces/Errors.sol";

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
contract BittyVault is Trust, AssetManager {
    // Full initialize with all parameters (used by factory)
    function initialize(
        address grantorAddress,
        address wethAddress,
        address wbtcAddress,
        address usdtAddress,
        address usdcAddress,
        address aaveV3Address,
        address uniswapV4RouterAddress
    ) external initializer {
        AssetManager._initialize(
            wethAddress, wbtcAddress, usdtAddress, usdcAddress, aaveV3Address, uniswapV4RouterAddress
        );

        if (grantorAddress == address(0)) {
            revert AddressZero();
        }
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        grantor = grantorAddress;
        isInitialized = true;
    }

    /**
     * @notice Returns USDT contract address
     * @dev Required by Trust.getMoney() to access stablecoin contracts
     * @return IERC20 The USDT contract interface
     */
    function usdt() external view override returns (IERC20) {
        return IERC20(assets(AssetType.USDT));
    }

    /**
     * @notice Returns USDC contract address
     * @dev Required by Trust.getMoney() to access stablecoin contracts
     * @return IERC20 The USDC contract interface
     */
    function usdc() external view override returns (IERC20) {
        return IERC20(assets(AssetType.USDC));
    }

    function wbtc() external view override returns (IERC20) {
        return IERC20(assets(AssetType.WBTC));
    }

    function weth() external view override returns (IERC20) {
        return IERC20(assets(AssetType.WETH));
    }

    /**
     * @notice Override revoke to transfer all assets to the grantor
     * @dev Transfers all assets (USDT, USDC, WBTC, WETH, ETH) and withdraws from Aave if needed
     */
    function revoke(address moneyWithdrawTo) external override onlyInitialized onlyGrantor {
        if (moneyWithdrawTo == address(0)) {
            revert AddressZero();
        }
        // Check if revocable (onlyRevocable modifier logic)
        if (!this.revocable()) {
            revert AddressZero();
        }

        // Convert ETH to WETH first if there's any ETH
        if (address(this).balance > 0) {
            _turnETHToWETH();
        }

        // Transfer all ERC20 assets
        _transferAllERC20(assets(AssetType.USDT), moneyWithdrawTo);
        _transferAllERC20(assets(AssetType.USDC), moneyWithdrawTo);
        _transferAllERC20(assets(AssetType.WBTC), moneyWithdrawTo);
        _transferAllERC20(assets(AssetType.WETH), moneyWithdrawTo);

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

    function supply(address assetAddress, uint256 amount) external onlyInitialized onlyAssetManager {
        _supply(assetAddress, amount);
    }

    function withdraw(address assetAddress, uint256 amount) external onlyInitialized onlyAssetManager {
        _withdraw(assetAddress, amount);
    }

    function rebalance(AssetType from, AssetType to, uint256 sellAmount, uint256 buyAmountMin, bytes calldata data)
        external
        onlyInitialized
        onlyAssetManager
    {
        _rebalance(from, to, sellAmount, buyAmountMin, data);
    }

    function sellAssetsNotWhiteListed(
        address sellAssetAddress,
        uint256 sellAmount,
        AssetType toAssetType,
        uint256 buyAmountMin,
        bytes calldata data
    ) external onlyInitialized onlyAssetManager {
        _swap(sellAssetAddress, sellAmount, assets(toAssetType), buyAmountMin, data);
    }

    function setRebalanceRules(RebalanceLimit memory rebalanceLimit) external onlyInitialized onlyTrustee {
        _setRebalanceRules(rebalanceLimit);
    }

    function turnETHToWETH() external onlyInitialized {
        _turnETHToWETH();
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
