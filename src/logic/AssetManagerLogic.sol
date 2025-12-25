// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IWhiteList} from "../interfaces/IWhiteList.sol";
import {IAssetManager, IProvider, IYieldProvider, ISwapProvider} from "../interfaces/IAssetManager.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {
    AddressZero,
    AmountIsZero,
    RebalanceInMinimalTime,
    InsufficientBalance,
    SellAmountMismatch,
    BuyAmountNotEnough,
    MinimalBalanceNotMet,
    NotInitialized,
    SupplyAmountMismatch,
    WithdrawAmountMismatch,
    InvalidYieldProvider,
    InvalidSwapProvider,
    Deprecated,
    NotWhiteListed,
    InvalidSwapData,
    AlreadyInitialized,
    BaseFeeDurationNotMet,
    RevenueDurationNotMet,
    RevenueIsZero,
    RevenuePercentageIsZero,
    RevenueDurationIsZero
} from "../interfaces/Errors.sol";
import {AssetManagerStorage, VaultStorage} from "./Storages.sol";
import {VaultLogic} from "./VaultLogic.sol";

library AssetManagerLogic {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address;
    using Clones for address;

    modifier onlyInitialized(AssetManagerStorage storage logicStorage) {
        _onlyInitialized(logicStorage);
        _;
    }

    function _onlyInitialized(AssetManagerStorage storage logicStorage) private view {
        if (!logicStorage.isInitialized) {
            revert NotInitialized();
        }
    }

    modifier onlyNotInitialized(AssetManagerStorage storage logicStorage) {
        _onlyNotInitialized(logicStorage);
        _;
    }

    function _onlyNotInitialized(AssetManagerStorage storage logicStorage) private view {
        if (logicStorage.isInitialized) {
            revert AlreadyInitialized();
        }
    }

    function initialize(AssetManagerStorage storage logicStorage, address whiteListAddress)
        external
        onlyNotInitialized(logicStorage)
    {
        if (whiteListAddress == address(0)) {
            revert AddressZero();
        }
        logicStorage.whiteList = IWhiteList(whiteListAddress);
        logicStorage.isInitialized = true;
    }

    function setAssetManager(AssetManagerStorage storage logicStorage, address assetManagerAddress)
        external
        onlyInitialized(logicStorage)
    {
        if (assetManagerAddress == address(0)) {
            revert AddressZero();
        }
        logicStorage.assetManager = assetManagerAddress;
    }

    function setManageFee(AssetManagerStorage storage logicStorage, IAssetManager.ManageFee memory manageFee_)
        external
        onlyInitialized(logicStorage)
    {
        if (manageFee_.baseFeeAmount == 0 && manageFee_.revenuePercentage == 0) {
            revert AmountIsZero();
        }
        if (manageFee_.revenuePercentage > 0 && manageFee_.revenueDuration == 0) {
            revert RevenueDurationIsZero();
        }
        if (manageFee_.revenuePercentage == 0 && manageFee_.revenueDuration > 0) {
            revert RevenuePercentageIsZero();
        }
        logicStorage.manageFee = manageFee_;
    }

    function _cloneProvider(AssetManagerStorage storage logicStorage, address provider)
        private
        onlyInitialized(logicStorage)
        returns (address clonedProvider)
    {
        clonedProvider = logicStorage.clonedProviders[provider];
        if (clonedProvider != address(0)) {
            return clonedProvider;
        }
        clonedProvider = provider.clone();
        IProvider(clonedProvider).initialize(address(this));
        logicStorage.clonedProviders[provider] = clonedProvider;
        return clonedProvider;
    }

    function getProviderInstance(AssetManagerStorage storage logicStorage, address provider)
        external
        view
        onlyInitialized(logicStorage)
        returns (address)
    {
        return logicStorage.clonedProviders[provider];
    }

    function cloneProvider(AssetManagerStorage storage logicStorage, address provider)
        external
        onlyInitialized(logicStorage)
        returns (address)
    {
        return _cloneProvider(logicStorage, provider);
    }

    function setRebalanceRules(
        AssetManagerStorage storage logicStorage,
        IAssetManager.RebalanceLimit memory rebalanceLimit_
    ) external onlyInitialized(logicStorage) {
        logicStorage.rebalanceLimit = rebalanceLimit_;
    }

    function setAssetConfig(
        AssetManagerStorage storage logicStorage,
        address assetAddress,
        IAssetManager.AssetConfig memory assetConfig
    ) external onlyInitialized(logicStorage) {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        logicStorage.assetConfigs[assetAddress] = assetConfig;
        logicStorage.assetConfigKeys.add(assetAddress);
    }

    function supply(
        AssetManagerStorage storage logicStorage,
        address yieldProvider,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        if (!logicStorage.yieldProviders.contains(yieldProvider)) {
            revert InvalidYieldProvider();
        }
        if (logicStorage.whiteList.isYieldProviderDeprecated(yieldProvider)) {
            revert Deprecated();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        // note: every asset manager should have its own yield provider instance
        yieldProvider = _cloneProvider(logicStorage, yieldProvider);
        uint256 balanceBefore = IYieldProvider(yieldProvider).getBalance(assetAddress);
        if (assetAddress == address(0)) {
            IYieldProvider(yieldProvider).supply{value: amount}(assetAddress, amount);
        } else {
            IERC20(assetAddress).safeApprove(yieldProvider, amount);
            IYieldProvider(yieldProvider).supply(assetAddress, amount);
            IERC20(assetAddress).safeApprove(yieldProvider, 0);
        }
        uint256 balanceAfter = IYieldProvider(yieldProvider).getBalance(assetAddress);
        if (balanceAfter - balanceBefore != amount) {
            revert SupplyAmountMismatch();
        }
    }

    function withdraw(
        AssetManagerStorage storage logicStorage,
        address yieldProvider,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        if (!logicStorage.yieldProviders.contains(yieldProvider)) {
            revert InvalidYieldProvider();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        // note: every asset manager should have its own yield provider instance
        yieldProvider = _cloneProvider(logicStorage, yieldProvider);
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

    function getBalance(AssetManagerStorage storage logicStorage, address yieldProvider, address assetAddress)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256)
    {
        if (!logicStorage.yieldProviders.contains(yieldProvider)) {
            revert InvalidYieldProvider();
        }
        address _clonedProvider = logicStorage.clonedProviders[yieldProvider];
        if (_clonedProvider == address(0)) {
            return 0;
        }
        return IYieldProvider(_clonedProvider).getBalance(assetAddress);
    }

    function _addressBalance(address assetAddress) private view returns (uint256) {
        if (assetAddress == address(0)) {
            return address(this).balance;
        }
        return IERC20(assetAddress).balanceOf(address(this));
    }

    function _checkSwapProvider(AssetManagerStorage storage logicStorage, address swapProvider) private view {
        if (!logicStorage.swapProviders.contains(swapProvider)) {
            revert InvalidSwapProvider();
        }
        if (!logicStorage.whiteList.isSwapProviderWhiteListed(swapProvider)) {
            revert NotWhiteListed();
        }
    }

    function rebalance(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address swapProvider,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external onlyInitialized(logicStorage) {
        if (from == address(0)) {
            revert AddressZero();
        }
        VaultLogic.checkAsset(vaultStorage, to);
        _checkSwapProvider(logicStorage, swapProvider);
        IAssetManager.AssetConfig memory assetConfigFrom = logicStorage.assetConfigs[from];
        IAssetManager.AssetConfig memory assetConfigTo = logicStorage.assetConfigs[to];
        if (
            logicStorage.rebalanceLimit.minimalTimestampBetweenRebalances > 0 && logicStorage.lastRebalanceTimestamp > 0
                && block.timestamp - logicStorage.lastRebalanceTimestamp
                    < logicStorage.rebalanceLimit.minimalTimestampBetweenRebalances
        ) {
            revert RebalanceInMinimalTime();
        }
        if (
            (assetConfigFrom.minimalDurationBetweenRebalances > 0
                    && logicStorage.lastRebalanceTimestamps[from] > 0
                    && block.timestamp - logicStorage.lastRebalanceTimestamps[from]
                        < assetConfigFrom.minimalDurationBetweenRebalances)
                || (assetConfigTo.minimalDurationBetweenRebalances > 0
                    && logicStorage.lastRebalanceTimestamps[to] > 0
                    && block.timestamp - logicStorage.lastRebalanceTimestamps[to]
                        < assetConfigTo.minimalDurationBetweenRebalances)
        ) {
            revert RebalanceInMinimalTime();
        }
        if (assetConfigFrom.minimalBalance > 0) {
            uint256 fromBalance = _addressBalance(from);
            if (fromBalance < sellAmount || fromBalance - sellAmount < assetConfigFrom.minimalBalance) {
                revert MinimalBalanceNotMet();
            }
        }
        if (vaultStorage.stableCoins.contains(from) && logicStorage.rebalanceLimit.minimalStableCoinBalance > 0) {
            uint256 stableCoinBalanceTotalBalance = 0;
            for (uint256 i = 0; i < vaultStorage.stableCoins.length(); i++) {
                stableCoinBalanceTotalBalance += _addressBalance(vaultStorage.stableCoins.at(i));
            }
            if (
                stableCoinBalanceTotalBalance < sellAmount
                    || stableCoinBalanceTotalBalance - sellAmount < logicStorage.rebalanceLimit.minimalStableCoinBalance
            ) {
                revert MinimalBalanceNotMet();
            }
        }

        _swap(logicStorage, swapProvider, from, sellAmount, to, buyAmountMin, data);

        if (assetConfigFrom.minimalDurationBetweenRebalances > 0) {
            logicStorage.lastRebalanceTimestamps[from] = block.timestamp;
            logicStorage.lastRebalanceTimestampKeys.add(from);
        }
        if (assetConfigTo.minimalDurationBetweenRebalances > 0) {
            logicStorage.lastRebalanceTimestamps[to] = block.timestamp;
            logicStorage.lastRebalanceTimestampKeys.add(to);
        }
        if (logicStorage.rebalanceLimit.minimalTimestampBetweenRebalances > 0) {
            logicStorage.lastRebalanceTimestamp = block.timestamp;
        }
    }

    function _swap(
        AssetManagerStorage storage logicStorage,
        address swapProvider,
        address sellAssetAddress,
        uint256 sellAmount,
        address toAssetAddress,
        uint256 buyAmountMin,
        bytes memory data
    ) private {
        if (sellAmount == 0 || buyAmountMin == 0) {
            revert AmountIsZero();
        }
        (address sellToken_, uint256 sellAmount_, address buyToken_, uint256 buyAmountMin_) =
            abi.decode(data, (address, uint256, address, uint256));
        if (
            sellToken_ != sellAssetAddress || sellAmount_ != sellAmount || buyToken_ != toAssetAddress
                || buyAmountMin_ != buyAmountMin
        ) {
            revert InvalidSwapData();
        }
        uint256 sellAssetBalanceBefore = _addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore < sellAmount) {
            revert InsufficientBalance();
        }
        uint256 buyAssetBalanceBefore = _addressBalance(toAssetAddress);

        // note: every asset manager should have its own swap provider instance
        swapProvider = _cloneProvider(logicStorage, swapProvider);

        ISwapProvider(swapProvider).swap(data);

        uint256 sellAssetBalanceAfter = _addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore - sellAssetBalanceAfter != sellAmount) {
            revert SellAmountMismatch();
        }
        uint256 buyAssetBalanceAfter = _addressBalance(toAssetAddress);
        if (buyAssetBalanceAfter - buyAssetBalanceBefore < buyAmountMin) {
            revert BuyAmountNotEnough();
        }
    }

    function getBaseFee(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address stableCoinAddress
    ) external onlyInitialized(logicStorage) {
        if (stableCoinAddress == address(0)) {
            revert AddressZero();
        }
        if (block.timestamp - logicStorage.lastBaseFeeTime < logicStorage.manageFee.baseFeeDuration) {
            revert BaseFeeDurationNotMet();
        }
        logicStorage.lastBaseFeeTime = block.timestamp;
        if (!logicStorage.manageFee.isBaseFeePercentage) {
            VaultLogic.getMoney(
                vaultStorage, logicStorage.manageFee.baseFeeAmount, stableCoinAddress, logicStorage.assetManager
            );
        } else {
            VaultLogic.getPercentageMoney(vaultStorage, logicStorage.manageFee.baseFeeAmount, logicStorage.assetManager);
        }
    }

    // TODO, when listing higher with buy low, sell to add revenues and get revenue fee from that
    function getRevenueFee(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address stableCoinAddress
    ) external onlyInitialized(logicStorage) {
        if (stableCoinAddress == address(0)) {
            revert AddressZero();
        }
        if (block.timestamp - logicStorage.lastRevenueTime < logicStorage.manageFee.revenueDuration) {
            revert RevenueDurationNotMet();
        }
        if (logicStorage.revenue == 0) {
            revert RevenueIsZero();
        }
        VaultLogic.getMoney(
            vaultStorage,
            logicStorage.revenue * logicStorage.manageFee.revenuePercentage / 10000,
            stableCoinAddress,
            logicStorage.assetManager
        );
        logicStorage.lastRevenueTime = block.timestamp;
        logicStorage.revenue = 0;
    }

    function addYieldProviders(AssetManagerStorage storage logicStorage, address[] memory yieldProviderAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < yieldProviderAddresses.length; i++) {
            if (!logicStorage.whiteList.isYieldProviderWhiteListed(yieldProviderAddresses[i])) {
                revert NotWhiteListed();
            }
            logicStorage.yieldProviders.add(yieldProviderAddresses[i]);
        }
    }

    function removeYieldProviders(AssetManagerStorage storage logicStorage, address[] memory yieldProviderAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < yieldProviderAddresses.length; i++) {
            logicStorage.yieldProviders.remove(yieldProviderAddresses[i]);
        }
    }

    function addSwapProviders(AssetManagerStorage storage logicStorage, address[] memory swapProviderAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < swapProviderAddresses.length; i++) {
            if (!logicStorage.whiteList.isSwapProviderWhiteListed(swapProviderAddresses[i])) {
                revert NotWhiteListed();
            }
            logicStorage.swapProviders.add(swapProviderAddresses[i]);
        }
    }

    function removeSwapProviders(AssetManagerStorage storage logicStorage, address[] memory swapProviderAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < swapProviderAddresses.length; i++) {
            logicStorage.swapProviders.remove(swapProviderAddresses[i]);
        }
    }

    function getYieldProviders(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.yieldProviders.values();
    }

    function getSwapProviders(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.swapProviders.values();
    }

    function getAllAssetConfigKeys(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.assetConfigKeys.values();
    }

    function getAllLastRebalanceTimestampKeys(AssetManagerStorage storage logicStorage)
        external
        view
        returns (address[] memory)
    {
        return logicStorage.lastRebalanceTimestampKeys.values();
    }
}
