// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {ITrustee} from "./interfaces/ITrustee.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IAssetManager, ILendingProvider, ISwapProvider} from "./interfaces/IAssetManager.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AddressZero,
    AmountIsZero,
    WETHNotSet,
    RebalanceInMinimalTime,
    InsufficientBalance,
    SellAmountMismatch,
    BuyAmountNotEnough,
    MinimalWBTCBalanceLimit,
    MinimalWETHBalanceLimit,
    MinimalStableCoinBalanceLimit,
    NotInitialized,
    SupplyAmountMismatch,
    WithdrawAmountMismatch,
    InvalidAssetType
} from "./interfaces/Errors.sol";
import {IWETH} from "./interfaces/IWETH.sol";

abstract contract AssetManager is IAssetManager, Initializable {
    using SafeERC20 for IERC20;
    mapping(AssetType => address) internal _assets;
    // only WETH and WBTC rebalance will be recorded
    mapping(AssetType => uint256) public lastRebalances;
    RebalanceLimit public rebalanceLimit;
    ILendingProvider public lendingProvider;
    ISwapProvider public swapProvider;

    modifier _onlyInitialized() {
        if (_getInitializedVersion() == 0) {
            revert NotInitialized();
        }
        _;
    }

    function assets(AssetType assetType) public view returns (address) {
        if (uint256(assetType) > uint256(AssetType.USDC)) {
            revert InvalidAssetType();
        }
        return _assets[assetType];
    }

    function _initialize(
        address wethAddress,
        address wbtcAddress,
        address usdtAddress,
        address usdcAddress,
        address lendingProvider_,
        address swapProvider_
    ) internal {
        if (wethAddress != address(0)) {
            _assets[AssetType.WETH] = wethAddress;
        }
        if (wbtcAddress != address(0)) {
            _assets[AssetType.WBTC] = wbtcAddress;
        }
        if (usdtAddress != address(0)) {
            _assets[AssetType.USDT] = usdtAddress;
        }
        if (usdcAddress != address(0)) {
            _assets[AssetType.USDC] = usdcAddress;
        }
        if (address(lendingProvider_) != address(0)) {
            lendingProvider = ILendingProvider(lendingProvider_);
        }
        if (address(swapProvider_) != address(0)) {
            swapProvider = ISwapProvider(swapProvider_);
        }
    }

    function _setRebalanceRules(RebalanceLimit memory rebalanceLimit_) internal _onlyInitialized {
        rebalanceLimit = rebalanceLimit_;
    }

    function _supply(address assetAddress, uint256 amount) internal _onlyInitialized {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        IERC20(assetAddress).safeApprove(address(lendingProvider), amount);
        uint256 balanceBefore = lendingProvider.getBalance(assetAddress);
        lendingProvider.supply(assetAddress, amount);
        IERC20(assetAddress).safeApprove(address(lendingProvider), 0);
        uint256 balanceAfter = lendingProvider.getBalance(assetAddress);
        if (balanceAfter - balanceBefore != amount) {
            revert SupplyAmountMismatch();
        }
    }

    function _withdraw(address assetAddress, uint256 amount) internal _onlyInitialized {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        uint256 supplyAmount = lendingProvider.getBalance(assetAddress);
        if (supplyAmount < amount) {
            revert InsufficientBalance();
        }
        uint256 balanceBefore = _addressBalance(assetAddress);
        lendingProvider.withdraw(assetAddress, amount);
        uint256 balanceAfter = _addressBalance(assetAddress);
        if (balanceAfter - balanceBefore != amount) {
            revert WithdrawAmountMismatch();
        }
    }

    function _assetBalance(AssetType assetType) internal view returns (uint256) {
        return IERC20(assets(assetType)).balanceOf(address(this));
    }

    function _addressBalance(address assetAddress) internal view returns (uint256) {
        if (assetAddress == address(0)) {
            return address(this).balance;
        }
        return IERC20(assetAddress).balanceOf(address(this));
    }

    function _rebalance(AssetType from, AssetType to, uint256 sellAmount, uint256 buyAmountMin, bytes memory data)
        internal
        _onlyInitialized
    {
        if ((from == AssetType.WETH || to == AssetType.WETH) && lastRebalances[AssetType.WETH] != 0) {
            if (block.timestamp - lastRebalances[AssetType.WETH] < rebalanceLimit.minimalTimestampBetweenRebalances) {
                revert RebalanceInMinimalTime();
            }
        }
        if ((from == AssetType.WBTC || to == AssetType.WBTC) && lastRebalances[AssetType.WBTC] != 0) {
            if (block.timestamp - lastRebalances[AssetType.WBTC] < rebalanceLimit.minimalTimestampBetweenRebalances) {
                revert RebalanceInMinimalTime();
            }
        }
        if (from == AssetType.WBTC) {
            if (_assetBalance(AssetType.WBTC) < (rebalanceLimit.minimalWBTCBalance + sellAmount)) {
                revert MinimalWBTCBalanceLimit();
            }
        } else if (from == AssetType.WETH) {
            if (_assetBalance(AssetType.WETH) < (rebalanceLimit.minimalWETHBalance + sellAmount)) {
                revert MinimalWETHBalanceLimit();
            }
        } else if ((from == AssetType.USDT || from == AssetType.USDC) && (to == AssetType.WETH || to == AssetType.WBTC))
        {
            if (
                _assetBalance(AssetType.USDT) + _assetBalance(AssetType.USDC)
                    < (rebalanceLimit.minimalStableCoinBalance + sellAmount)
            ) {
                revert MinimalStableCoinBalanceLimit();
            }
        }

        _swap(assets(from), sellAmount, assets(to), buyAmountMin, data);

        if (from == AssetType.WETH || to == AssetType.WETH) {
            lastRebalances[AssetType.WETH] = block.timestamp;
        }
        if (from == AssetType.WBTC || to == AssetType.WBTC) {
            lastRebalances[AssetType.WBTC] = block.timestamp;
        }
    }

    //TODO: verify data is matching with the parms
    function _swap(
        address sellAssetAddress,
        uint256 sellAmount,
        address buyAssetAddress,
        uint256 buyAmountMin,
        bytes memory data
    ) internal _onlyInitialized {
        if (sellAmount == 0 || buyAmountMin == 0) {
            revert AmountIsZero();
        }
        uint256 sellAssetBalanceBefore = _addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore < sellAmount) {
            revert InsufficientBalance();
        }
        uint256 buyAssetBalanceBefore = _addressBalance(buyAssetAddress);
        if (sellAssetAddress == address(0)) {
            swapProvider.swap{value: sellAmount}(data);
        } else {
            swapProvider.swap(data);
        }

        uint256 sellAssetBalanceAfter = _addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore - sellAssetBalanceAfter != sellAmount) {
            revert SellAmountMismatch();
        }
        uint256 buyAssetBalanceAfter = _addressBalance(buyAssetAddress);
        if (buyAssetBalanceAfter - buyAssetBalanceBefore < buyAmountMin) {
            revert BuyAmountNotEnough();
        }
    }

    function getETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function _turnETHToWETH() internal _onlyInitialized {
        if (address(assets(AssetType.WETH)) == address(0)) {
            revert WETHNotSet();
        }
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            IWETH(assets(AssetType.WETH)).deposit{value: ethBalance}();
        }
    }

    function getWETHBalance() external view returns (uint256) {
        if (address(assets(AssetType.WETH)) == address(0)) {
            revert WETHNotSet();
        }
        return IWETH(assets(AssetType.WETH)).balanceOf(address(this));
    }

    receive() external payable {}

    fallback() external payable {}
}
