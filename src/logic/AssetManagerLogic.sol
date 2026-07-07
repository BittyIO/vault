// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IBittyV1Guard, NotRegistered, Deprecated} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {
    IBittyV1AssetManager,
    DisableRebalanceUntilTimestampTooEarly,
    DisableRebalanceUntilTimestampTooLong,
    RebalanceDisabled,
    SellAmountMismatch,
    BuyAmountNotEnough,
    MinimalBalanceNotMet,
    InvalidLendingProtocol,
    InvalidStakingProtocol,
    InvalidAMMProtocol,
    InvalidIntentProtocol,
    InvalidValidTo,
    InvalidSwapData
} from "../interfaces/IBittyV1AssetManager.sol";
import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {IBittyV1LendingProtocol} from "protocol-contracts/src/interfaces/IBittyV1LendingProtocol.sol";
import {IBittyV1StakingProtocol} from "protocol-contracts/src/interfaces/IBittyV1StakingProtocol.sol";
import {IBittyV1AMMProtocol} from "protocol-contracts/src/interfaces/IBittyV1AMMProtocol.sol";
import {
    IBittyV1IntentProtocol,
    OrderNotExpired,
    ActiveTwapExists
} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
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
} from "../interfaces/IBittyV1Vault.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ETHBalanceNotEnough, WETHBalanceNotEnough} from "../interfaces/IBittyV1AssetManager.sol";
import {AssetManagerStorage, VaultStorage, IntentOrderRecord} from "./Storages.sol";
import {VaultLogic} from "./VaultLogic.sol";

library AssetManagerLogic {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address;
    using Clones for address;

    uint256 constant REBALANCE_DISABLE_MAX_DURATION = 4 * 365 days;

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
        logicStorage.guard = IBittyV1Guard(guardAddress);
        logicStorage.weth = wethAddress;
        logicStorage.isInitialized = true;
    }

    function getClone(AssetManagerStorage storage logicStorage, address protocol) external view returns (address) {
        return logicStorage.clonedProtocols[protocol];
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
        IBittyV1Protocol(clonedProtocol).initialize(address(this));
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

    function setMinimalBalance(AssetManagerStorage storage logicStorage, address assetAddress, uint256 minimalBalance)
        external
        onlyInitialized(logicStorage)
    {
        if (assetAddress == address(0)) revert AddressZero();
        logicStorage.minimalBalances[assetAddress] = minimalBalance;
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
        if (IERC20(assetAddress).allowance(address(this), lendingProtocol) < amount) {
            IERC20(assetAddress).forceApprove(lendingProtocol, type(uint256).max);
        }
        IBittyV1LendingProtocol(lendingProtocol).supply(assetAddress, amount);
    }

    function withdraw(
        AssetManagerStorage storage logicStorage,
        address lendingProtocol,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        lendingProtocol = logicStorage.clonedProtocols[lendingProtocol];
        if (lendingProtocol == address(0)) {
            revert InvalidLendingProtocol();
        }
        if (amount != type(uint256).max) {
            uint256 supplyAmount = IBittyV1LendingProtocol(lendingProtocol).getSuppliedBalance(assetAddress);
            if (supplyAmount < amount) {
                revert InsufficientBalance();
            }
        }
        _approveReceiptToken(lendingProtocol, assetAddress);
        IBittyV1LendingProtocol(lendingProtocol).withdraw(assetAddress, amount);
    }

    function getSuppliedBalance(AssetManagerStorage storage logicStorage, address lendingProtocol, address assetAddress)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256)
    {
        address _clonedProtocol = logicStorage.clonedProtocols[lendingProtocol];
        if (_clonedProtocol == address(0)) {
            return 0;
        }
        return IBittyV1LendingProtocol(_clonedProtocol).getSuppliedBalance(assetAddress);
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
        if (IERC20(assetAddress).allowance(address(this), stakingProtocol) < amount) {
            IERC20(assetAddress).forceApprove(stakingProtocol, type(uint256).max);
        }
        IBittyV1StakingProtocol(stakingProtocol).stake(assetAddress, amount);
    }

    function unstake(
        AssetManagerStorage storage logicStorage,
        address stakingProtocol,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        stakingProtocol = logicStorage.clonedProtocols[stakingProtocol];
        if (stakingProtocol == address(0)) {
            revert InvalidStakingProtocol();
        }
        if (amount != type(uint256).max) {
            uint256 stakingBalance = IBittyV1StakingProtocol(stakingProtocol).getStakedBalance(assetAddress);
            if (stakingBalance < amount) {
                revert InsufficientBalance();
            }
        }
        _approveReceiptToken(stakingProtocol, assetAddress);
        IBittyV1StakingProtocol(stakingProtocol).unstake(assetAddress, amount);
    }

    function getStakedBalance(AssetManagerStorage storage logicStorage, address stakingProtocol, address assetAddress)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256)
    {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        address _clonedProtocol = logicStorage.clonedProtocols[stakingProtocol];
        if (_clonedProtocol == address(0)) {
            return 0;
        }
        return IBittyV1StakingProtocol(_clonedProtocol).getStakedBalance(assetAddress);
    }

    function getUnstakeRequestIds(AssetManagerStorage storage logicStorage, address stakingProtocol)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256[] memory)
    {
        address _clonedProtocol = logicStorage.clonedProtocols[stakingProtocol];
        if (_clonedProtocol == address(0)) {
            return new uint256[](0);
        }
        return IBittyV1StakingProtocol(_clonedProtocol).getUnstakeRequestIds();
    }

    function claimUnstaked(
        AssetManagerStorage storage logicStorage,
        address stakingProtocol,
        uint256[] memory requestIds
    ) external onlyInitialized(logicStorage) {
        if (requestIds.length == 0) {
            return;
        }
        stakingProtocol = logicStorage.clonedProtocols[stakingProtocol];
        if (stakingProtocol == address(0)) {
            revert InvalidStakingProtocol();
        }
        IBittyV1StakingProtocol(stakingProtocol).claimUnstaked(requestIds);
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
            if (balance > 0 && IERC20(receiptToken).allowance(address(this), protocol) < balance) {
                IERC20(receiptToken).forceApprove(protocol, type(uint256).max);
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
        if (
            !logicStorage.guard.isAMMProtocolRegistered(ammProtocol)
                && !logicStorage.guard.isAMMProtocolDeprecated(ammProtocol)
        ) {
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
    ) private view {
        VaultLogic.checkAsset(vaultStorage, from);
        VaultLogic.checkAsset(vaultStorage, to);
        _checkRebalanceDisabledUntilTimestamp(logicStorage);
        uint256 minBal = logicStorage.minimalBalances[from];
        if (minBal > 0) {
            uint256 bal = _addressBalance(from);
            if (bal < sellAmount || bal - sellAmount < minBal) revert MinimalBalanceNotMet();
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
        if (logicStorage.guard.isAMMProtocolDeprecated(ammProtocol)) revert Deprecated();
        address clone = _cloneProtocol(logicStorage, ammProtocol);
        if (token0 != address(0) && amount0 > 0 && IERC20(token0).allowance(address(this), clone) < amount0) {
            IERC20(token0).forceApprove(clone, type(uint256).max);
        }
        if (token1 != address(0) && amount1 > 0 && IERC20(token1).allowance(address(this), clone) < amount1) {
            IERC20(token1).forceApprove(clone, type(uint256).max);
        }
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).addLiquidity(data);
    }

    function removeLiquidity(AssetManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) revert InvalidAMMProtocol();
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).removeLiquidity(data);
    }

    function decreaseLiquidity(AssetManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) revert InvalidAMMProtocol();
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).decreaseLiquidity(data);
    }

    function claimAMMFees(AssetManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) revert InvalidAMMProtocol();
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).claimAMMFees(data);
    }

    function marketSell(
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
        if (logicStorage.guard.isAMMProtocolDeprecated(ammProtocol)) revert Deprecated();
        _validateRebalance(logicStorage, vaultStorage, from, to, sellAmount);
        _swapExactIn(logicStorage, ammProtocol, from, sellAmount, to, buyAmountMin, data);
    }

    function marketBuy(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address ammProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        bytes memory data
    ) external onlyInitialized(logicStorage) {
        _checkAMMProtocol(logicStorage, ammProtocol);
        if (logicStorage.guard.isAMMProtocolDeprecated(ammProtocol)) revert Deprecated();
        _validateRebalance(logicStorage, vaultStorage, from, to, sellAmountMax);
        _swapExactOut(logicStorage, ammProtocol, from, sellAmountMax, to, buyAmount, data);
    }

    function _swapExactIn(
        AssetManagerStorage storage logicStorage,
        address ammProtocol,
        address sellAssetAddress,
        uint256 sellAmount,
        address toAssetAddress,
        uint256 buyAmountMin,
        bytes memory data
    ) private {
        if (sellAmount == 0 || buyAmountMin == 0) revert AmountIsZero();
        (address sellToken_, uint256 sellAmount_, address buyToken_, uint256 buyAmountMin_) =
            abi.decode(data, (address, uint256, address, uint256));
        if (
            sellToken_ != sellAssetAddress || sellAmount_ != sellAmount || buyToken_ != toAssetAddress
                || buyAmountMin_ != buyAmountMin
        ) revert InvalidSwapData();

        uint256 sellAssetBalanceBefore = _addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore < sellAmount) revert InsufficientBalance();
        uint256 buyAssetBalanceBefore = _addressBalance(toAssetAddress);

        ammProtocol = _cloneProtocol(logicStorage, ammProtocol);
        if (IERC20(sellAssetAddress).allowance(address(this), ammProtocol) < sellAmount) {
            IERC20(sellAssetAddress).forceApprove(ammProtocol, type(uint256).max);
        }
        IBittyV1AMMProtocol(ammProtocol).swap(data);

        if (_addressBalance(sellAssetAddress) != sellAssetBalanceBefore - sellAmount) revert SellAmountMismatch();
        if (_addressBalance(toAssetAddress) - buyAssetBalanceBefore < buyAmountMin) revert BuyAmountNotEnough();
    }

    function _swapExactOut(
        AssetManagerStorage storage logicStorage,
        address ammProtocol,
        address sellAssetAddress,
        uint256 sellAmountMax,
        address toAssetAddress,
        uint256 buyAmount,
        bytes memory data
    ) private {
        if (buyAmount == 0 || sellAmountMax == 0) revert AmountIsZero();
        (address sellToken_, uint256 sellAmountMax_, address buyToken_, uint256 buyAmount_) =
            abi.decode(data, (address, uint256, address, uint256));
        if (
            sellToken_ != sellAssetAddress || sellAmountMax_ != sellAmountMax || buyToken_ != toAssetAddress
                || buyAmount_ != buyAmount
        ) revert InvalidSwapData();

        uint256 sellAssetBalanceBefore = _addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore < sellAmountMax) revert InsufficientBalance();
        uint256 buyAssetBalanceBefore = _addressBalance(toAssetAddress);

        ammProtocol = _cloneProtocol(logicStorage, ammProtocol);
        if (IERC20(sellAssetAddress).allowance(address(this), ammProtocol) < sellAmountMax) {
            IERC20(sellAssetAddress).forceApprove(ammProtocol, type(uint256).max);
        }
        IBittyV1AMMProtocol(ammProtocol).swapExactOut(data);

        if (sellAssetBalanceBefore - _addressBalance(sellAssetAddress) > sellAmountMax) revert SellAmountMismatch();
        if (_addressBalance(toAssetAddress) - buyAssetBalanceBefore < buyAmount) revert BuyAmountNotEnough();
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
        if (timestamp > block.timestamp + REBALANCE_DISABLE_MAX_DURATION) {
            revert DisableRebalanceUntilTimestampTooLong();
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
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) return 0;
        return IBittyV1AMMProtocol(clone).getLiquidity(data);
    }

    // ============ Intent protocols ============

    function _checkIntentProtocol(AssetManagerStorage storage logicStorage, address intentProtocol) private view {
        if (!logicStorage.intentProtocols.contains(intentProtocol)) revert InvalidIntentProtocol();
        if (logicStorage.guard.isIntentProtocolDeprecated(intentProtocol)) revert Deprecated();
        if (!logicStorage.guard.isIntentProtocolRegistered(intentProtocol)) revert NotRegistered();
    }

    function _executeCancel(AssetManagerStorage storage logicStorage, address intentProtocol, bytes32 orderId) private {
        address clone = logicStorage.clonedProtocols[intentProtocol];
        IBittyV1IntentProtocol.CancelInstructions memory instr =
            IBittyV1IntentProtocol(clone).buildCancelInstructions(orderId);
        if (instr.cancelTarget != address(0)) {
            instr.cancelTarget.functionCall(instr.cancelCalldata);
        }
        delete logicStorage.intentOrderRecords[orderId];
    }

    function limitSell(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address intentProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        uint32 validTo
    ) external onlyInitialized(logicStorage) returns (bytes32 orderId) {
        _checkIntentProtocol(logicStorage, intentProtocol);
        _validateRebalance(logicStorage, vaultStorage, from, to, sellAmount);
        orderId = _intentTrade(logicStorage, intentProtocol, from, sellAmount, to, buyAmountMin, validTo, true);
    }

    function limitBuy(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address intentProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        uint32 validTo
    ) external onlyInitialized(logicStorage) returns (bytes32 orderId) {
        _checkIntentProtocol(logicStorage, intentProtocol);
        _validateRebalance(logicStorage, vaultStorage, from, to, sellAmountMax);
        orderId = _intentTrade(logicStorage, intentProtocol, from, sellAmountMax, to, buyAmount, validTo, false);
    }

    function _intentTrade(
        AssetManagerStorage storage logicStorage,
        address intentProtocol,
        address sellAssetAddress,
        uint256 sellAmount,
        address toAssetAddress,
        uint256 buyAmountMin,
        uint32 validTo,
        bool isSellOrder
    ) private returns (bytes32 orderId) {
        if (sellAmount == 0 || buyAmountMin == 0) revert AmountIsZero();
        if (validTo <= block.timestamp) revert InvalidValidTo();

        address clone = _cloneProtocol(logicStorage, intentProtocol);
        bytes memory data = abi.encode(sellAssetAddress, sellAmount, toAssetAddress, buyAmountMin, validTo, isSellOrder);

        IBittyV1IntentProtocol.OrderInstructions memory instr =
            IBittyV1IntentProtocol(clone).buildLimitOrderInstructions(data);
        orderId = instr.orderId;

        if (instr.registerTarget != address(0)) {
            instr.registerTarget.functionCall(instr.registerCalldata);
        }

        if (
            instr.approveTarget != address(0) && instr.sellAmount > 0
                && IERC20(instr.sellToken).allowance(address(this), instr.approveTarget) < instr.sellAmount
        ) {
            IERC20(instr.sellToken).forceApprove(instr.approveTarget, type(uint256).max);
        }

        logicStorage.intentOrderRecords[orderId] =
            IntentOrderRecord({sellToken: instr.sellToken, expiresAt: uint256(validTo)});

        emit IBittyV1IntentProtocol.OrderCreated(orderId, address(this));
    }

    function cancelLimitOrder(AssetManagerStorage storage logicStorage, address intentProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        if (logicStorage.clonedProtocols[intentProtocol] == address(0)) revert InvalidIntentProtocol();

        bytes32 orderId = abi.decode(data, (bytes32));
        if (logicStorage.intentOrderRecords[orderId].sellToken == address(0)) revert InvalidIntentProtocol();

        _executeCancel(logicStorage, intentProtocol, orderId);
        emit IBittyV1IntentProtocol.OrderCancelled(orderId, address(this));
    }

    /// @notice Permissionless cleanup of expired limit orders (does not affect TWAP orders).
    ///         Reverts if any order is still live.
    function cleanExpiredLimitOrders(
        AssetManagerStorage storage logicStorage,
        address intentProtocol,
        bytes32[] calldata orderDigests
    ) external onlyInitialized(logicStorage) {
        if (logicStorage.clonedProtocols[intentProtocol] == address(0)) {
            revert InvalidIntentProtocol();
        }

        for (uint256 i = 0; i < orderDigests.length; i++) {
            bytes32 orderId = orderDigests[i];
            IntentOrderRecord memory record = logicStorage.intentOrderRecords[orderId];
            if (record.expiresAt == 0 || block.timestamp <= record.expiresAt) revert OrderNotExpired();
            _executeCancel(logicStorage, intentProtocol, orderId);
        }
    }

    function addIntentProtocols(AssetManagerStorage storage logicStorage, address[] memory intentProtocolAddresses)
        external
        onlyAddingProtocolsEnabled(logicStorage)
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < intentProtocolAddresses.length; i++) {
            if (!logicStorage.guard.isIntentProtocolRegistered(intentProtocolAddresses[i])) revert NotRegistered();
            logicStorage.intentProtocols.add(intentProtocolAddresses[i]);
        }
    }

    function removeIntentProtocols(AssetManagerStorage storage logicStorage, address[] memory intentProtocolAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < intentProtocolAddresses.length; i++) {
            logicStorage.intentProtocols.remove(intentProtocolAddresses[i]);
        }
    }

    function getIntentProtocols(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.intentProtocols.values();
    }

    function twapSell(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address intentProtocol,
        address from,
        address to,
        uint256 totalSellAmount,
        uint256 minPartLimit,
        uint256 n,
        uint256 partDuration,
        uint256 span
    ) external onlyInitialized(logicStorage) returns (bytes32 twapId) {
        _checkIntentProtocol(logicStorage, intentProtocol);
        if (totalSellAmount == 0 || minPartLimit == 0 || n == 0 || partDuration == 0) revert AmountIsZero();
        _validateRebalance(logicStorage, vaultStorage, from, to, totalSellAmount);

        // at most one active TWAP per sell token
        if (logicStorage.activeTwapPerToken[from] != bytes32(0)) revert ActiveTwapExists(from);

        address clone = _cloneProtocol(logicStorage, intentProtocol);
        bytes memory data = abi.encode(from, totalSellAmount, to, minPartLimit, n, partDuration, span);

        (IBittyV1IntentProtocol.OrderInstructions memory instr, uint256 expiresAt_) =
            IBittyV1IntentProtocol(clone).buildTwapInstructions(data);
        twapId = instr.orderId;

        if (instr.registerTarget != address(0)) {
            instr.registerTarget.functionCall(instr.registerCalldata);
        }

        if (
            instr.approveTarget != address(0) && instr.sellAmount > 0
                && IERC20(instr.sellToken).allowance(address(this), instr.approveTarget) < instr.sellAmount
        ) {
            IERC20(instr.sellToken).forceApprove(instr.approveTarget, type(uint256).max);
        }

        logicStorage.intentOrderRecords[twapId] = IntentOrderRecord({sellToken: instr.sellToken, expiresAt: expiresAt_});
        logicStorage.activeTwapPerToken[instr.sellToken] = twapId;

        emit IBittyV1IntentProtocol.TwapCreated(twapId, address(this));
    }

    function twapBuy(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address intentProtocol,
        address from,
        address to,
        uint256 totalBuyAmount,
        uint256 sellAmountPerPart,
        uint256 n,
        uint256 partDuration,
        uint256 span
    ) external onlyInitialized(logicStorage) returns (bytes32 twapId) {
        _checkIntentProtocol(logicStorage, intentProtocol);
        if (totalBuyAmount == 0 || sellAmountPerPart == 0 || n == 0 || partDuration == 0) revert AmountIsZero();
        uint256 minPartLimit = totalBuyAmount / n;
        if (minPartLimit == 0) revert AmountIsZero();
        uint256 totalSellAmount = sellAmountPerPart * n;
        _validateRebalance(logicStorage, vaultStorage, from, to, totalSellAmount);

        // at most one active TWAP per sell token
        if (logicStorage.activeTwapPerToken[from] != bytes32(0)) revert ActiveTwapExists(from);

        address clone = _cloneProtocol(logicStorage, intentProtocol);
        bytes memory data = abi.encode(from, totalSellAmount, to, minPartLimit, n, partDuration, span);

        (IBittyV1IntentProtocol.OrderInstructions memory instr, uint256 expiresAt_) =
            IBittyV1IntentProtocol(clone).buildTwapInstructions(data);
        twapId = instr.orderId;

        if (instr.registerTarget != address(0)) {
            instr.registerTarget.functionCall(instr.registerCalldata);
        }

        if (
            instr.approveTarget != address(0) && instr.sellAmount > 0
                && IERC20(instr.sellToken).allowance(address(this), instr.approveTarget) < instr.sellAmount
        ) {
            IERC20(instr.sellToken).forceApprove(instr.approveTarget, type(uint256).max);
        }

        logicStorage.intentOrderRecords[twapId] = IntentOrderRecord({sellToken: instr.sellToken, expiresAt: expiresAt_});
        logicStorage.activeTwapPerToken[instr.sellToken] = twapId;

        emit IBittyV1IntentProtocol.TwapCreated(twapId, address(this));
    }

    function cancelTwapOrder(AssetManagerStorage storage logicStorage, address intentProtocol, bytes32 twapId)
        external
        onlyInitialized(logicStorage)
    {
        IntentOrderRecord memory record = logicStorage.intentOrderRecords[twapId];
        if (record.sellToken == address(0)) revert InvalidIntentProtocol();

        delete logicStorage.activeTwapPerToken[record.sellToken];

        _executeCancel(logicStorage, intentProtocol, twapId);

        emit IBittyV1IntentProtocol.TwapCancelled(twapId, address(this));
    }
}
