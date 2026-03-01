// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IWhiteList, NotWhiteListed, Deprecated} from "../interfaces/IWhiteList.sol";
import {
    IAssetManager,
    DisableRebalanceUntilTimestampTooEarly,
    RebalanceDisabled,
    RebalanceInMinimalTime,
    RebalanceMaxPercentage,
    SellAmountMismatch,
    BuyAmountNotEnough,
    MinimalBalanceNotMet,
    InvalidLendingProvider,
    InvalidStakingProvider,
    InvalidSwapProvider,
    InvalidSwapData
} from "../interfaces/IAssetManager.sol";
import {IProvider} from "../interfaces/IProvider.sol";
import {ILendingProvider} from "../interfaces/ILendingProvider.sol";
import {IStakingProvider} from "../interfaces/IStakingProvider.sol";
import {IAMMProvider} from "../interfaces/IAMMProvider.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {
    AddressZero,
    AmountIsZero,
    InsufficientBalance,
    NotInitialized,
    AlreadyInitialized
} from "../interfaces/IVault.sol";
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

    function cloneProvider(AssetManagerStorage storage logicStorage, address provider)
        external
        onlyInitialized(logicStorage)
        returns (address)
    {
        return _cloneProvider(logicStorage, provider);
    }

    function getOrCloneSwapProvider(AssetManagerStorage storage logicStorage, address ammProvider)
        external
        onlyInitialized(logicStorage)
        returns (address clone)
    {
        _checkSwapProvider(logicStorage, ammProvider);
        return _cloneProvider(logicStorage, ammProvider);
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
        address lendingProvider,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        if (!logicStorage.lendingProviders.contains(lendingProvider)) {
            revert InvalidLendingProvider();
        }
        if (logicStorage.whiteList.isLendingProviderDeprecated(lendingProvider)) {
            revert Deprecated();
        }
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        lendingProvider = _cloneProvider(logicStorage, lendingProvider);
        IERC20(assetAddress).safeIncreaseAllowance(lendingProvider, amount);
        ILendingProvider(lendingProvider).supply(assetAddress, amount);
        uint256 remaining = IERC20(assetAddress).allowance(address(this), lendingProvider);
        if (remaining > 0) {
            IERC20(assetAddress).safeDecreaseAllowance(lendingProvider, remaining);
        }
    }

    function withdraw(
        AssetManagerStorage storage logicStorage,
        address lendingProvider,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        if (!logicStorage.lendingProviders.contains(lendingProvider)) {
            revert InvalidLendingProvider();
        }
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        lendingProvider = _cloneProvider(logicStorage, lendingProvider);
        uint256 supplyAmount = ILendingProvider(lendingProvider).getLendingBalance(assetAddress);
        if (supplyAmount < amount) {
            revert InsufficientBalance();
        }
        ILendingProvider(lendingProvider).withdraw(assetAddress, amount);
    }

    function getLendingBalance(AssetManagerStorage storage logicStorage, address lendingProvider, address assetAddress)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256)
    {
        if (!logicStorage.lendingProviders.contains(lendingProvider)) {
            revert InvalidLendingProvider();
        }
        address _clonedProvider = logicStorage.clonedProviders[lendingProvider];
        if (_clonedProvider == address(0)) {
            return 0;
        }
        return ILendingProvider(_clonedProvider).getLendingBalance(assetAddress);
    }

    function stake(
        AssetManagerStorage storage logicStorage,
        address stakingProvider,
        address wethAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        if (!logicStorage.stakingProviders.contains(stakingProvider)) {
            revert InvalidStakingProvider();
        }
        if (logicStorage.whiteList.isStakingProviderDeprecated(stakingProvider)) {
            revert Deprecated();
        }
        if (wethAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        stakingProvider = _cloneProvider(logicStorage, stakingProvider);
        IERC20(wethAddress).safeIncreaseAllowance(stakingProvider, amount);
        IStakingProvider(stakingProvider).stake(amount);
        uint256 remaining = IERC20(wethAddress).allowance(address(this), stakingProvider);
        if (remaining > 0) {
            IERC20(wethAddress).safeDecreaseAllowance(stakingProvider, remaining);
        }
    }

    function unstake(
        AssetManagerStorage storage logicStorage,
        address stakingProvider,
        address wethAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        if (!logicStorage.stakingProviders.contains(stakingProvider)) {
            revert InvalidStakingProvider();
        }
        if (wethAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        stakingProvider = _cloneProvider(logicStorage, stakingProvider);
        uint256 stakingBalance = IStakingProvider(stakingProvider).getStakingBalance();
        if (stakingBalance < amount) {
            revert InsufficientBalance();
        }
        IStakingProvider(stakingProvider).unstake(amount);
    }

    function getStakingBalance(AssetManagerStorage storage logicStorage, address stakingProvider)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256)
    {
        if (!logicStorage.stakingProviders.contains(stakingProvider)) {
            revert InvalidStakingProvider();
        }
        address _clonedProvider = logicStorage.clonedProviders[stakingProvider];
        if (_clonedProvider == address(0)) {
            return 0;
        }
        return IStakingProvider(_clonedProvider).getStakingBalance();
    }

    function getUnstakeRequestIds(AssetManagerStorage storage logicStorage, address stakingProvider)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256[] memory)
    {
        if (!logicStorage.stakingProviders.contains(stakingProvider)) {
            revert InvalidStakingProvider();
        }

        address _clonedProvider = logicStorage.clonedProviders[stakingProvider];
        if (_clonedProvider == address(0)) {
            return new uint256[](0);
        }
        return IStakingProvider(_clonedProvider).getUnstakeRequestIds();
    }

    function _addressBalance(address assetAddress) private view returns (uint256) {
        if (assetAddress == address(0)) {
            revert AddressZero();
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

    function _checkRebalanceDisabledUntilTimestamp(AssetManagerStorage storage logicStorage) private view {
        if (
            logicStorage.rebalanceDisabledUntilTimestamp > 0
                && block.timestamp < logicStorage.rebalanceDisabledUntilTimestamp
        ) {
            revert RebalanceDisabled();
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
        _checkRebalanceDisabledUntilTimestamp(logicStorage);
        IAssetManager.AssetConfig memory assetConfigFrom = logicStorage.assetConfigs[from];
        IAssetManager.AssetConfig memory assetConfigTo = logicStorage.assetConfigs[to];
        uint256 fromBalance = _addressBalance(from);

        if (assetConfigFrom.maxRebalancePercentage > 0) {
            if (sellAmount * 10000 > fromBalance * assetConfigFrom.maxRebalancePercentage) {
                revert RebalanceMaxPercentage();
            }
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
            if (fromBalance < sellAmount || fromBalance - sellAmount < assetConfigFrom.minimalBalance) {
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

        swapProvider = _cloneProvider(logicStorage, swapProvider);

        IERC20(sellAssetAddress).safeIncreaseAllowance(swapProvider, sellAmount);
        IAMMProvider(swapProvider).swap(data);
        uint256 remaining = IERC20(sellAssetAddress).allowance(address(this), swapProvider);
        if (remaining > 0) {
            IERC20(sellAssetAddress).safeDecreaseAllowance(swapProvider, remaining);
        }

        uint256 sellAssetBalanceAfter = _addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore - sellAssetBalanceAfter != sellAmount) {
            revert SellAmountMismatch();
        }
        uint256 buyAssetBalanceAfter = _addressBalance(toAssetAddress);
        if (buyAssetBalanceAfter - buyAssetBalanceBefore < buyAmountMin) {
            revert BuyAmountNotEnough();
        }
    }

    function disableRebalanceUntilTimestamp(AssetManagerStorage storage logicStorage, uint256 timestamp)
        external
        onlyInitialized(logicStorage)
    {
        if (timestamp == 0) {
            return;
        }
        if (timestamp < logicStorage.rebalanceDisabledUntilTimestamp) {
            revert DisableRebalanceUntilTimestampTooEarly();
        }
        logicStorage.rebalanceDisabledUntilTimestamp = timestamp;
    }

    function addLendingProviders(AssetManagerStorage storage logicStorage, address[] memory lendingProviderAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < lendingProviderAddresses.length; i++) {
            if (!logicStorage.whiteList.isLendingProviderWhiteListed(lendingProviderAddresses[i])) {
                revert NotWhiteListed();
            }
            logicStorage.lendingProviders.add(lendingProviderAddresses[i]);
        }
    }

    function addStakingProviders(AssetManagerStorage storage logicStorage, address[] memory stakingProviderAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < stakingProviderAddresses.length; i++) {
            if (!logicStorage.whiteList.isStakingProviderWhiteListed(stakingProviderAddresses[i])) {
                revert NotWhiteListed();
            }
            logicStorage.stakingProviders.add(stakingProviderAddresses[i]);
        }
    }

    function removeLendingProviders(AssetManagerStorage storage logicStorage, address[] memory lendingProviderAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < lendingProviderAddresses.length; i++) {
            logicStorage.lendingProviders.remove(lendingProviderAddresses[i]);
        }
    }

    function removeStakingProviders(AssetManagerStorage storage logicStorage, address[] memory stakingProviderAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < stakingProviderAddresses.length; i++) {
            logicStorage.stakingProviders.remove(stakingProviderAddresses[i]);
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

    function getLendingProviders(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.lendingProviders.values();
    }

    function getStakingProviders(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.stakingProviders.values();
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

    function getLiquidity(AssetManagerStorage storage logicStorage, address ammProvider, bytes memory data)
        external
        view
        returns (uint256)
    {
        _checkSwapProvider(logicStorage, ammProvider);
        address clone = logicStorage.clonedProviders[ammProvider];
        if (clone == address(0)) return 0;
        return IAMMProvider(clone).getLiquidity(data);
    }
}
