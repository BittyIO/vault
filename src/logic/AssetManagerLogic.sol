// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IGuard, NotRegistered, Deprecated} from "guard-contracts/src/interfaces/IGuard.sol";
import {
    IAssetManager,
    DisableRebalanceUntilTimestampTooEarly,
    RebalanceDisabled,
    RebalanceInMinimalTime,
    RebalanceMaxAmount,
    SellAmountMismatch,
    BuyAmountNotEnough,
    MinimalBalanceNotMet,
    InvalidLendingProtocol,
    InvalidStakingProtocol,
    InvalidAMMProtocol,
    InvalidSwapData
} from "../interfaces/IAssetManager.sol";
import {IProtocol} from "protocol-contracts/src/interfaces/IProtocol.sol";
import {ILendingProtocol} from "protocol-contracts/src/interfaces/ILendingProtocol.sol";
import {IStakingProtocol} from "protocol-contracts/src/interfaces/IStakingProtocol.sol";
import {IAMMProtocol} from "protocol-contracts/src/interfaces/IAMMProtocol.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {
    AddressZero,
    AmountIsZero,
    InsufficientBalance,
    NotInitialized,
    AlreadyInitialized,
    AddingProtocolsDisabled
} from "../interfaces/IVault.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ETHBalanceNotEnough, WETHBalanceNotEnough} from "../interfaces/IAssetManager.sol";
import {AssetManagerStorage, VaultStorage} from "./Storages.sol";
import {VaultLogic} from "./VaultLogic.sol";

library AssetManagerLogic {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address;
    using Clones for address;

    modifier onlyInitialized(AssetManagerStorage storage logicStorage) {
        if (!logicStorage.isInitialized) {
            revert NotInitialized();
        }
        _;
    }

    modifier onlyNotInitialized(AssetManagerStorage storage logicStorage) {
        if (logicStorage.isInitialized) {
            revert AlreadyInitialized();
        }
        _;
    }

    modifier onlyAddingProtocolsEnabled(AssetManagerStorage storage logicStorage) {
        if (logicStorage.addingProtocolsDisabled) {
            revert AddingProtocolsDisabled();
        }
        _;
    }

    function initialize(AssetManagerStorage storage logicStorage, address guardAddress, address wethAddress)
        external
        onlyNotInitialized(logicStorage)
    {
        if (guardAddress == address(0)) {
            revert AddressZero();
        }
        logicStorage.guard = IGuard(guardAddress);
        logicStorage.weth = wethAddress;
        logicStorage.isInitialized = true;
    }

    function _cloneProtocol(AssetManagerStorage storage logicStorage, address protocol)
        private
        onlyInitialized(logicStorage)
        returns (address clonedProtocol)
    {
        clonedProtocol = logicStorage.clonedProtocols[protocol];
        if (clonedProtocol != address(0)) {
            return clonedProtocol;
        }
        clonedProtocol = protocol.clone();
        IProtocol(clonedProtocol).initialize(address(this));
        logicStorage.clonedProtocols[protocol] = clonedProtocol;
        return clonedProtocol;
    }

    function ETHToWETH(AssetManagerStorage storage logicStorage, uint256 amount)
        external
        onlyInitialized(logicStorage)
    {
        uint256 ethBalance = address(this).balance;
        if (ethBalance < amount) {
            revert ETHBalanceNotEnough();
        }
        WETH(payable(logicStorage.weth)).deposit{value: amount}();
    }

    function WETHToETH(AssetManagerStorage storage logicStorage, uint256 amount)
        external
        onlyInitialized(logicStorage)
    {
        uint256 wethBalance = IERC20(logicStorage.weth).balanceOf(address(this));
        if (wethBalance < amount) {
            revert WETHBalanceNotEnough();
        }
        WETH(payable(logicStorage.weth)).withdraw(amount);
    }

    function setRebalanceConfig(
        AssetManagerStorage storage logicStorage,
        address assetAddress,
        IAssetManager.RebalanceConfig memory assetConfig
    ) external onlyInitialized(logicStorage) {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        logicStorage.rebalanceConfigs[assetAddress] = assetConfig;
    }

    function supply(
        AssetManagerStorage storage logicStorage,
        address lendingProtocol,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        if (!logicStorage.lendingProtocols.contains(lendingProtocol)) {
            revert InvalidLendingProtocol();
        }
        if (logicStorage.guard.isLendingProtocolDeprecated(lendingProtocol)) {
            revert Deprecated();
        }
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        lendingProtocol = _cloneProtocol(logicStorage, lendingProtocol);
        IERC20(assetAddress).safeIncreaseAllowance(lendingProtocol, amount);
        ILendingProtocol(lendingProtocol).supply(assetAddress, amount);
    }

    function withdraw(
        AssetManagerStorage storage logicStorage,
        address lendingProtocol,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        if (!logicStorage.lendingProtocols.contains(lendingProtocol)) {
            revert InvalidLendingProtocol();
        }
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        lendingProtocol = _cloneProtocol(logicStorage, lendingProtocol);
        uint256 supplyAmount = ILendingProtocol(lendingProtocol).getSuppliedBalance(assetAddress);
        if (supplyAmount < amount) {
            revert InsufficientBalance();
        }
        _approveReceiptToken(lendingProtocol, assetAddress);
        ILendingProtocol(lendingProtocol).withdraw(assetAddress, amount);
    }

    function getSuppliedBalance(AssetManagerStorage storage logicStorage, address lendingProtocol, address assetAddress)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256)
    {
        if (!logicStorage.lendingProtocols.contains(lendingProtocol)) {
            revert InvalidLendingProtocol();
        }
        address _clonedProtocol = logicStorage.clonedProtocols[lendingProtocol];
        if (_clonedProtocol == address(0)) {
            return 0;
        }
        return ILendingProtocol(_clonedProtocol).getSuppliedBalance(assetAddress);
    }

    function stake(
        AssetManagerStorage storage logicStorage,
        address stakingProtocol,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        if (!logicStorage.stakingProtocols.contains(stakingProtocol)) {
            revert InvalidStakingProtocol();
        }
        if (logicStorage.guard.isStakingProtocolDeprecated(stakingProtocol)) {
            revert Deprecated();
        }
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        stakingProtocol = _cloneProtocol(logicStorage, stakingProtocol);
        IERC20(assetAddress).safeIncreaseAllowance(stakingProtocol, amount);
        IStakingProtocol(stakingProtocol).stake(assetAddress, amount);
    }

    function unstake(
        AssetManagerStorage storage logicStorage,
        address stakingProtocol,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        if (!logicStorage.stakingProtocols.contains(stakingProtocol)) {
            revert InvalidStakingProtocol();
        }
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        stakingProtocol = _cloneProtocol(logicStorage, stakingProtocol);
        uint256 stakingBalance = IStakingProtocol(stakingProtocol).getStakedBalance(assetAddress);
        if (stakingBalance < amount) {
            revert InsufficientBalance();
        }
        _approveReceiptToken(stakingProtocol, assetAddress);
        IStakingProtocol(stakingProtocol).unstake(assetAddress, amount);
    }

    function getStakedBalance(AssetManagerStorage storage logicStorage, address stakingProtocol, address assetAddress)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256)
    {
        if (!logicStorage.stakingProtocols.contains(stakingProtocol)) {
            revert InvalidStakingProtocol();
        }
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        address _clonedProtocol = logicStorage.clonedProtocols[stakingProtocol];
        if (_clonedProtocol == address(0)) {
            return 0;
        }
        return IStakingProtocol(_clonedProtocol).getStakedBalance(assetAddress);
    }

    function getUnstakeRequestIds(AssetManagerStorage storage logicStorage, address stakingProtocol)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256[] memory)
    {
        if (!logicStorage.stakingProtocols.contains(stakingProtocol)) {
            revert InvalidStakingProtocol();
        }

        address _clonedProtocol = logicStorage.clonedProtocols[stakingProtocol];
        if (_clonedProtocol == address(0)) {
            return new uint256[](0);
        }
        return IStakingProtocol(_clonedProtocol).getUnstakeRequestIds();
    }

    function claimUnstaked(
        AssetManagerStorage storage logicStorage,
        address stakingProtocol,
        uint256[] memory requestIds
    ) external onlyInitialized(logicStorage) {
        if (!logicStorage.stakingProtocols.contains(stakingProtocol)) {
            revert InvalidStakingProtocol();
        }
        if (requestIds.length == 0) {
            return;
        }
        stakingProtocol = _cloneProtocol(logicStorage, stakingProtocol);
        IStakingProtocol(stakingProtocol).claimUnstaked(requestIds);
    }

    function _getReceiptToken(address protocol, address asset) private view returns (address) {
        (bool success, bytes memory data) =
            protocol.staticcall(abi.encodeWithSignature("receiptTokenOf(address)", asset));
        if (success && data.length >= 32) {
            return abi.decode(data, (address));
        }
        return address(0);
    }

    function _approveReceiptToken(address protocol, address asset) private {
        address receiptToken = _getReceiptToken(protocol, asset);
        if (receiptToken != address(0)) {
            uint256 balance = IERC20(receiptToken).balanceOf(address(this));
            if (balance > 0) {
                IERC20(receiptToken).safeIncreaseAllowance(protocol, balance);
            }
        }
    }

    function _approveNFTIfNeeded(address protocol) private {
        (bool success, bytes memory data) = protocol.staticcall(abi.encodeWithSignature("positionManager()"));
        if (!success || data.length < 32) return;
        address nft = abi.decode(data, (address));
        (bool success2, bytes memory result) =
            nft.staticcall(abi.encodeWithSignature("isApprovedForAll(address,address)", address(this), protocol));
        if (!success2 || result.length < 32) return;
        bool approved = abi.decode(result, (bool));
        if (!approved) {
            nft.functionCall(abi.encodeWithSignature("setApprovalForAll(address,bool)", protocol, true));
        }
    }

    function _addressBalance(address assetAddress) private view returns (uint256) {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        return IERC20(assetAddress).balanceOf(address(this));
    }

    function _checkAMMProtocol(AssetManagerStorage storage logicStorage, address ammProtocol) private view {
        if (!logicStorage.ammProtocols.contains(ammProtocol)) {
            revert InvalidAMMProtocol();
        }
        if (!logicStorage.guard.isAMMProtocolRegistered(ammProtocol)) {
            revert NotRegistered();
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

    function _validateRebalance(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address from,
        address to,
        uint256 sellAmount
    )
        private
        view
        returns (IAssetManager.RebalanceConfig memory configFrom, IAssetManager.RebalanceConfig memory configTo)
    {
        VaultLogic.checkAsset(vaultStorage, from);
        VaultLogic.checkAsset(vaultStorage, to);
        _checkRebalanceDisabledUntilTimestamp(logicStorage);
        configFrom = logicStorage.rebalanceConfigs[from];
        configTo = logicStorage.rebalanceConfigs[to];

        if (
            configFrom.maxAmount == 0 && configFrom.minimalBalance == 0 && configFrom.minimalDuration == 0
                && configTo.maxAmount == 0 && configTo.minimalBalance == 0 && configTo.minimalDuration == 0
        ) {
            return (configFrom, configTo);
        }

        if (configFrom.maxAmount > 0 && configFrom.maxAmount < sellAmount) {
            revert RebalanceMaxAmount();
        }

        uint256 fromBalance = _addressBalance(from);

        if (configFrom.minimalBalance > 0) {
            if (fromBalance < sellAmount || fromBalance - sellAmount < configFrom.minimalBalance) {
                revert MinimalBalanceNotMet();
            }
        }

        if (
            (configFrom.minimalDuration > 0
                    && logicStorage.lastRebalanceTimestamps[from] > 0
                    && block.timestamp - logicStorage.lastRebalanceTimestamps[from] < configFrom.minimalDuration)
                || (configTo.minimalDuration > 0
                    && logicStorage.lastRebalanceTimestamps[to] > 0
                    && block.timestamp - logicStorage.lastRebalanceTimestamps[to] < configTo.minimalDuration)
        ) {
            revert RebalanceInMinimalTime();
        }

        return (configFrom, configTo);
    }

    function _updateRebalanceTimestamps(
        AssetManagerStorage storage logicStorage,
        IAssetManager.RebalanceConfig memory assetConfigFrom,
        IAssetManager.RebalanceConfig memory assetConfigTo,
        address from,
        address to
    ) private {
        if (assetConfigFrom.minimalDuration > 0) {
            logicStorage.lastRebalanceTimestamps[from] = block.timestamp;
        }
        if (assetConfigTo.minimalDuration > 0) {
            logicStorage.lastRebalanceTimestamps[to] = block.timestamp;
        }
    }

    function addLiquidity(
        AssetManagerStorage storage logicStorage,
        address ammProtocol,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external onlyInitialized(logicStorage) {
        _checkAMMProtocol(logicStorage, ammProtocol);
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) {
            revert InvalidAMMProtocol();
        }
        if (token0 != address(0) && amount0 > 0 && IERC20(token0).allowance(address(this), clone) < amount0) {
            IERC20(token0).safeIncreaseAllowance(clone, amount0);
        }
        if (token1 != address(0) && amount1 > 0 && IERC20(token1).allowance(address(this), clone) < amount1) {
            IERC20(token1).safeIncreaseAllowance(clone, amount1);
        }
        _approveNFTIfNeeded(clone);
        IAMMProtocol(clone).addLiquidity(data);
    }

    function removeLiquidity(AssetManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        _checkAMMProtocol(logicStorage, ammProtocol);
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) {
            revert InvalidAMMProtocol();
        }
        _approveNFTIfNeeded(clone);
        IAMMProtocol(clone).removeLiquidity(data);
    }

    function claimAMMFees(AssetManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        _checkAMMProtocol(logicStorage, ammProtocol);
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) {
            revert InvalidAMMProtocol();
        }
        _approveNFTIfNeeded(clone);
        IAMMProtocol(clone).claimAMMFees(data);
    }

    function rebalance(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address ammProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external onlyInitialized(logicStorage) {
        _checkAMMProtocol(logicStorage, ammProtocol);
        (IAssetManager.RebalanceConfig memory assetConfigFrom, IAssetManager.RebalanceConfig memory assetConfigTo) =
            _validateRebalance(logicStorage, vaultStorage, from, to, sellAmount);
        _swap(logicStorage, ammProtocol, from, sellAmount, to, buyAmountMin, data);
        _updateRebalanceTimestamps(logicStorage, assetConfigFrom, assetConfigTo, from, to);
    }

    function _swap(
        AssetManagerStorage storage logicStorage,
        address ammProtocol,
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

        ammProtocol = _cloneProtocol(logicStorage, ammProtocol);

        if (IERC20(sellAssetAddress).allowance(address(this), ammProtocol) < sellAmount) {
            IERC20(sellAssetAddress).safeIncreaseAllowance(ammProtocol, sellAmount);
        }
        IAMMProtocol(ammProtocol).swap(data);

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

    function disableAddingProtocols(AssetManagerStorage storage logicStorage) external onlyInitialized(logicStorage) {
        logicStorage.addingProtocolsDisabled = true;
    }

    function addLendingProtocols(AssetManagerStorage storage logicStorage, address[] memory lendingProtocolAddresses)
        external
        onlyAddingProtocolsEnabled(logicStorage)
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < lendingProtocolAddresses.length; i++) {
            if (!logicStorage.guard.isLendingProtocolRegistered(lendingProtocolAddresses[i])) {
                revert NotRegistered();
            }
            logicStorage.lendingProtocols.add(lendingProtocolAddresses[i]);
        }
    }

    function addStakingProtocols(AssetManagerStorage storage logicStorage, address[] memory stakingProtocolAddresses)
        external
        onlyAddingProtocolsEnabled(logicStorage)
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < stakingProtocolAddresses.length; i++) {
            if (!logicStorage.guard.isStakingProtocolRegistered(stakingProtocolAddresses[i])) {
                revert NotRegistered();
            }
            logicStorage.stakingProtocols.add(stakingProtocolAddresses[i]);
        }
    }

    function removeLendingProtocols(AssetManagerStorage storage logicStorage, address[] memory lendingProtocolAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < lendingProtocolAddresses.length; i++) {
            logicStorage.lendingProtocols.remove(lendingProtocolAddresses[i]);
        }
    }

    function removeStakingProtocols(AssetManagerStorage storage logicStorage, address[] memory stakingProtocolAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < stakingProtocolAddresses.length; i++) {
            logicStorage.stakingProtocols.remove(stakingProtocolAddresses[i]);
        }
    }

    function addAMMProtocols(AssetManagerStorage storage logicStorage, address[] memory ammProtocolAddresses)
        external
        onlyAddingProtocolsEnabled(logicStorage)
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < ammProtocolAddresses.length; i++) {
            if (!logicStorage.guard.isAMMProtocolRegistered(ammProtocolAddresses[i])) {
                revert NotRegistered();
            }
            logicStorage.ammProtocols.add(ammProtocolAddresses[i]);
        }
    }

    function removeAMMProtocols(AssetManagerStorage storage logicStorage, address[] memory ammProtocolAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < ammProtocolAddresses.length; i++) {
            logicStorage.ammProtocols.remove(ammProtocolAddresses[i]);
        }
    }

    function getLendingProtocols(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.lendingProtocols.values();
    }

    function getStakingProtocols(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.stakingProtocols.values();
    }

    function getAMMProtocols(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.ammProtocols.values();
    }

    function getLiquidity(AssetManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        view
        returns (uint256)
    {
        _checkAMMProtocol(logicStorage, ammProtocol);
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) return 0;
        return IAMMProtocol(clone).getLiquidity(data);
    }
}
