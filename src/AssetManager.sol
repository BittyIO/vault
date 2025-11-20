// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {ITrustee} from "./interfaces/ITrustee.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IAssetManager, IYieldProvider, ISwapProvider} from "./interfaces/IAssetManager.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IWhiteList} from "./interfaces/IWhiteList.sol";
import {
    AddressZero,
    AmountIsZero,
    WETHNotSet,
    RebalanceInMinimalTime,
    InsufficientBalance,
    SellAmountMismatch,
    BuyAmountNotEnough,
    MinimalBalanceNotMet,
    NotInitialized,
    SupplyAmountMismatch,
    WithdrawAmountMismatch,
    InvalidAssetType,
    InvalidStableCoinType,
    InvalidYieldProvider,
    InvalidSwapProvider,
    Deprecated,
    NotWhiteListed,
    InvalidSwapData
} from "./interfaces/Errors.sol";
import {IWETH} from "./interfaces/IWETH.sol";

abstract contract AssetManager is IAssetManager, Initializable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    address public wethAddress;
    IWhiteList public whiteList;
    EnumerableSet.AddressSet internal _assets;
    EnumerableSet.AddressSet internal _stableCoins;
    mapping(address => bool) internal _yieldProviders;
    mapping(address => bool) internal _swapProviders;
    mapping(address => IAssetManager.AssetConfig) internal _assetConfigs;
    mapping(address => uint256) internal lastRebalanceTimestamps;
    uint256 public lastRebalanceTimestamp;
    RebalanceLimit public rebalanceLimit;

    modifier _onlyInitialized() {
        if (_getInitializedVersion() == 0) {
            revert NotInitialized();
        }
        _;
    }

    function _initialize(
        address wethAddress_,
        address whiteListAddress_,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory yieldProviders,
        address[] memory swapProviders
    ) internal {
        if (wethAddress_ == address(0)) {
            revert AddressZero();
        }
        wethAddress = wethAddress_;
        whiteList = IWhiteList(whiteListAddress_);
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (assetAddresses[i] == address(0)) {
                revert AddressZero();
            }
            _assets.add(assetAddresses[i]);
        }
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (stableCoinAddresses[i] == address(0)) {
                revert AddressZero();
            }
            _stableCoins.add(stableCoinAddresses[i]);
        }
        for (uint256 i = 0; i < yieldProviders.length; i++) {
            if (yieldProviders[i] == address(0)) {
                revert AddressZero();
            }
            _yieldProviders[yieldProviders[i]] = true;
        }
        for (uint256 i = 0; i < swapProviders.length; i++) {
            if (swapProviders[i] == address(0)) {
                revert AddressZero();
            }
            _swapProviders[swapProviders[i]] = true;
        }
    }

    function _setRebalanceRules(RebalanceLimit memory rebalanceLimit_) internal _onlyInitialized {
        rebalanceLimit = rebalanceLimit_;
    }

    function _supply(address yieldProvider, address assetAddress, uint256 amount) internal _onlyInitialized {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        if (!_yieldProviders[yieldProvider]) {
            revert InvalidYieldProvider();
        }
        if (whiteList.isYieldProviderDeprecated(yieldProvider)) {
            revert Deprecated();
        }
        if (!whiteList.isYieldProviderWhiteListed(yieldProvider)) {
            revert NotWhiteListed();
        }
        IERC20(assetAddress).safeApprove(address(yieldProvider), amount);
        uint256 balanceBefore = IYieldProvider(yieldProvider).getBalance(assetAddress);
        IYieldProvider(yieldProvider).supply(assetAddress, amount);
        IERC20(assetAddress).safeApprove(address(yieldProvider), 0);
        uint256 balanceAfter = IYieldProvider(yieldProvider).getBalance(assetAddress);
        if (balanceAfter - balanceBefore != amount) {
            revert SupplyAmountMismatch();
        }
    }

    function _withdraw(address yieldProvider, address assetAddress, uint256 amount) internal _onlyInitialized {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        if (!_yieldProviders[yieldProvider]) {
            revert InvalidYieldProvider();
        }
        if (!whiteList.isYieldProviderDeprecated(yieldProvider) && !whiteList.isYieldProviderWhiteListed(yieldProvider))
        {
            revert NotWhiteListed();
        }
        uint256 supplyAmount = IYieldProvider(yieldProvider).getBalance(assetAddress);
        if (supplyAmount < amount) {
            revert InsufficientBalance();
        }
        uint256 balanceBefore = _addressBalance(assetAddress);
        IYieldProvider(yieldProvider).withdraw(assetAddress, amount);
        uint256 balanceAfter = _addressBalance(assetAddress);
        if (balanceAfter - balanceBefore != amount) {
            revert WithdrawAmountMismatch();
        }
    }

    function _addressBalance(address assetAddress) internal view returns (uint256) {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        return IERC20(assetAddress).balanceOf(address(this));
    }

    function _rebalance(
        address swapProvider,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) internal _onlyInitialized {
        if (
            (!_assets.contains(from) && !_stableCoins.contains(from))
                || (!_assets.contains(to) && !_stableCoins.contains(to))
        ) {
            revert InvalidAssetType();
        }
        if (
            !(whiteList.isAssetWhiteListed(to) || whiteList.isStableCoinWhiteListed(to))
                || !whiteList.isSwapProviderWhiteListed(swapProvider)
        ) {
            revert NotWhiteListed();
        }
        AssetConfig memory assetConfigFrom = _assetConfigs[from];
        AssetConfig memory assetConfigTo = _assetConfigs[to];
        if (
            rebalanceLimit.minimalTimestampBetweenRebalances > 0 && lastRebalanceTimestamp > 0
                && block.timestamp - lastRebalanceTimestamp < rebalanceLimit.minimalTimestampBetweenRebalances
        ) {
            revert RebalanceInMinimalTime();
        }
        if (
            (assetConfigFrom.minimalDurationBetweenRebalances > 0
                    && lastRebalanceTimestamps[from] > 0
                    && block.timestamp - lastRebalanceTimestamps[from]
                        < assetConfigFrom.minimalDurationBetweenRebalances)
                || (assetConfigTo.minimalDurationBetweenRebalances > 0
                    && lastRebalanceTimestamps[to] > 0
                    && block.timestamp - lastRebalanceTimestamps[to] < assetConfigTo.minimalDurationBetweenRebalances)
        ) {
            revert RebalanceInMinimalTime();
        }
        if (assetConfigFrom.minimalBalance > 0 && _addressBalance(from) - sellAmount < assetConfigFrom.minimalBalance) {
            revert MinimalBalanceNotMet();
        }
        if (_stableCoins.contains(from) && rebalanceLimit.minimalStableCoinBalance > 0) {
            uint256 stableCoinBalanceTotalBalance = 0;
            for (uint256 i = 0; i < _stableCoins.length(); i++) {
                stableCoinBalanceTotalBalance += _addressBalance(_stableCoins.at(i));
            }
            if (stableCoinBalanceTotalBalance - sellAmount < rebalanceLimit.minimalStableCoinBalance) {
                revert MinimalBalanceNotMet();
            }
        }

        _swap(swapProvider, from, sellAmount, to, buyAmountMin, data);

        if (assetConfigFrom.minimalDurationBetweenRebalances > 0) {
            lastRebalanceTimestamps[from] = block.timestamp;
        }
        if (assetConfigTo.minimalDurationBetweenRebalances > 0) {
            lastRebalanceTimestamps[to] = block.timestamp;
        }
        if (rebalanceLimit.minimalTimestampBetweenRebalances > 0) {
            lastRebalanceTimestamp = block.timestamp;
        }
    }

    function _swap(
        address swapProvider,
        address sellAssetAddress,
        uint256 sellAmount,
        address toAssetType,
        uint256 buyAmountMin,
        bytes memory data
    ) internal _onlyInitialized {
        if (!_swapProviders[swapProvider]) {
            revert InvalidSwapProvider();
        }
        if (sellAmount == 0 || buyAmountMin == 0) {
            revert AmountIsZero();
        }
        (address sellToken_, uint256 sellAmount_, address buyToken_, uint256 buyAmountMin_) =
            abi.decode(data, (address, uint256, address, uint256));
        if (
            sellToken_ != sellAssetAddress || sellAmount_ != sellAmount || buyToken_ != toAssetType
                || buyAmountMin_ != buyAmountMin
        ) {
            revert InvalidSwapData();
        }
        if (!_assets.contains(toAssetType) && !_stableCoins.contains(toAssetType)) {
            revert NotWhiteListed();
        }
        if (!whiteList.isAssetWhiteListed(toAssetType) && !whiteList.isStableCoinWhiteListed(toAssetType)) {
            revert NotWhiteListed();
        }
        uint256 sellAssetBalanceBefore = _addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore < sellAmount) {
            revert InsufficientBalance();
        }
        uint256 buyAssetBalanceBefore = _addressBalance(toAssetType);

        ISwapProvider(swapProvider).swap(data);

        uint256 sellAssetBalanceAfter = _addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore - sellAssetBalanceAfter != sellAmount) {
            revert SellAmountMismatch();
        }
        uint256 buyAssetBalanceAfter = _addressBalance(toAssetType);
        if (buyAssetBalanceAfter - buyAssetBalanceBefore < buyAmountMin) {
            revert BuyAmountNotEnough();
        }
    }

    function _turnETHToWETH() internal _onlyInitialized {
        if (wethAddress == address(0)) {
            revert WETHNotSet();
        }
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            IWETH(wethAddress).deposit{value: ethBalance}();
        }
    }

    function getAssets() external view override returns (address[] memory) {
        return _assets.values();
    }

    function getStableCoins() external view override returns (address[] memory) {
        return _stableCoins.values();
    }

    receive() external payable {}

    fallback() external payable {}
}
