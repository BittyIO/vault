// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {
    AlreadyInitialized,
    AddressZero,
    AmountIsZero,
    NotInitialized,
    InsufficientBalance,
    TransferFailed,
    ReentrantCall,
    ArrayLengthMismatch,
    EmptyArray,
    NoRescueTarget,
    OnlyImmutablePayableAfterRenounce,
    IBittyV1Vault,
    ScheduledPaymentNotFound,
    ScheduledPaymentImmutable,
    ImmutableScheduledPaymentLocked,
    ScheduledPaymentPaymentCountZero,
    ScheduledPaymentTriggerError,
    ScheduledPaymentNotStartYet,
    ScheduledPaymentStartTimestampInPast,
    ScheduledPaymentInInterval,
    AddingAssetsDisabled,
    AssetAddressNotContract,
    ProtectionPeriodNotEnded,
    PaymentProtectionTooLong,
    PayMoreThanScheduledPaymentAmount,
    PayScheduledPaymentAmountTriggerEmpty,
    WhitelistedRecipientNotFound,
    WhitelistedRecipientAssetNotAllowed,
    PaymentNotApproved,
    NotPendingApproval,
    NotProposalOwner,
    ScheduledPaymentContentMismatch,
    WhitelistedRecipientContentMismatch,
    PendingSendNotFound,
    PaymentExceedsRiskCap,
    PaymentExceedsPeriodLimit,
    PaymentNotStableCoin,
    PayoutOperatorNotFound,
    PayoutOperatorAlreadyRegistered,
    GasBudgetExceeded,
    GasBudgetTooHigh,
    FeeExceedsPerOpCap
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {IBittyV1PayoutOperator} from "../interfaces/IBittyV1PayoutOperator.sol";
import {IBittyV1Guard, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {VaultStorage, PendingSend, RiskConfig, TimelockedValue} from "./Storages.sol";
import {BITTY_GUARD, BITTY_FEE_COLLECTOR} from "./Constants.sol";

library VaultLogic {
    uint64 constant MAX_PAYMENT_PROTECTION = 3650 days;

    uint256 constant UNCHANGED = type(uint256).max;

    uint64 constant DAILY_MAX_GAS_BUDGET = 100;

    uint64 constant MAX_FEE_PER_OP = 10;

    using EnumerableSet for EnumerableSet.AddressSet;
    /**
     * @dev Transient slot for the native-ETH payout reentrancy lock. Transient rather than storage
     *      because the flag is only ever meaningful inside one transaction: it costs 100 gas instead of
     *      a ~20,000-gas SSTORE pair, and EIP-1153 clears it at the end of the transaction, so no revert
     *      path can leave the vault wedged with the lock held.
     */
    bytes32 private constant _PAYING_ETH_SLOT = 0x4a13bb800a6acf269bf38b83515e655524477341d6fee628cc6a83e97cf77054; // keccak256("bitty.v1.vault.payingEth")

    using SafeERC20 for IERC20;

    modifier onlyInitialized(VaultStorage storage vaultStorage) {
        _onlyInitialized(vaultStorage);
        _;
    }

    function _onlyInitialized(VaultStorage storage vaultStorage) private view {
        if (!vaultStorage.isInitialized) {
            revert NotInitialized();
        }
    }

    modifier onlyNotInitialized(VaultStorage storage vaultStorage) {
        _onlyNotInitialized(vaultStorage);
        _;
    }

    function _onlyNotInitialized(VaultStorage storage vaultStorage) private view {
        if (vaultStorage.isInitialized) {
            revert AlreadyInitialized();
        }
    }

    function initialize(VaultStorage storage vaultStorage) external onlyNotInitialized(vaultStorage) {
        vaultStorage.isInitialized = true;
    }

    function _dailyLimit(VaultStorage storage vaultStorage) private view returns (uint64) {
        if (vaultStorage.gaslessDisabled) return 0;
        uint64 owned = _effective(vaultStorage.gasBudgetDaily);
        return owned == 0 ? DAILY_MAX_GAS_BUDGET : owned;
    }

    function _effective(TimelockedValue storage tv) private view returns (uint64) {
        if (tv.pendingAt != 0 && block.timestamp >= tv.pendingAt) return tv.pending;
        return tv.value;
    }

    function effectiveChangeTimelock(VaultStorage storage vaultStorage) external view returns (uint64) {
        return _effective(vaultStorage.riskConfig.changeTimelock);
    }

    function _settle(TimelockedValue storage tv) private {
        if (tv.pendingAt != 0 && block.timestamp >= tv.pendingAt) {
            tv.value = tv.pending;
            tv.pending = 0;
            tv.pendingAt = 0;
        }
    }

    function _apply(TimelockedValue storage tv, uint64 next, bool loosen, uint64 timelock) private {
        if (!loosen || timelock == 0) {
            tv.value = next;
            tv.pending = 0;
            tv.pendingAt = 0;
        } else {
            tv.pending = next;
            tv.pendingAt = uint64(block.timestamp) + timelock;
        }
    }

    function _setHigherSafer(TimelockedValue storage tv, uint256 next, uint64 timelock) private {
        _settle(tv);
        uint64 n = uint64(next);
        _apply(tv, n, n < tv.value, timelock);
    }

    function _setCap(TimelockedValue storage tv, uint256 next, uint64 timelock) private {
        _settle(tv);
        uint64 n = uint64(next);
        bool loosen = tv.value != 0 && (n == 0 || n > tv.value);
        _apply(tv, n, loosen, timelock);
    }

    function _setGasBudget(TimelockedValue storage tv, uint64 next, uint64 timelock) private {
        _settle(tv);
        bool loosen = next == 0 || (tv.value != 0 && next > tv.value);
        _apply(tv, next, loosen, timelock);
    }

    function enableGasless(VaultStorage storage vaultStorage) external onlyInitialized(vaultStorage) {
        if (!vaultStorage.gaslessDisabled) return;
        vaultStorage.gaslessDisabled = false;
        emit IBittyV1Owner.GaslessSet(true, new address[](0), 0, 0);
    }

    function disableGasless(VaultStorage storage vaultStorage) external onlyInitialized(vaultStorage) {
        vaultStorage.gaslessDisabled = true;
        emit IBittyV1Owner.GaslessSet(false, new address[](0), 0, 0);
    }

    function setGasless(
        VaultStorage storage vaultStorage,
        address[] calldata stableCoins,
        uint64 dailyLimit,
        uint64 maxFeePerOp
    ) external onlyInitialized(vaultStorage) {
        if (dailyLimit > DAILY_MAX_GAS_BUDGET) revert GasBudgetTooHigh();
        if (maxFeePerOp > MAX_FEE_PER_OP) revert FeeExceedsPerOpCap();

        EnumerableSet.AddressSet storage allowed = vaultStorage.gaslessStableCoins;
        for (uint256 i = allowed.length(); i > 0; i--) {
            allowed.remove(allowed.at(i - 1));
        }
        for (uint256 i = 0; i < stableCoins.length; i++) {
            if (!IBittyV1Guard(BITTY_GUARD).isStableCoinRegistered(stableCoins[i])) revert PaymentNotStableCoin();
            allowed.add(stableCoins[i]);
        }

        vaultStorage.gaslessDisabled = false;

        uint64 timelock = _effective(vaultStorage.riskConfig.changeTimelock);
        _setGasBudget(vaultStorage.gasBudgetDaily, dailyLimit, timelock);

        _setGasBudget(vaultStorage.maxFeePerOp, maxFeePerOp, timelock);

        emit IBittyV1Owner.GaslessSet(true, stableCoins, dailyLimit, maxFeePerOp);
    }

    function getGaslessStableCoins(VaultStorage storage vaultStorage) external view returns (address[] memory) {
        return vaultStorage.gaslessStableCoins.values();
    }

    function _feePerOpCap(VaultStorage storage vaultStorage) private view returns (uint64) {
        uint64 owned = _effective(vaultStorage.maxFeePerOp);
        return owned == 0 ? MAX_FEE_PER_OP : owned;
    }

    function maxFeePerOpValue(VaultStorage storage vaultStorage) external view returns (uint256) {
        return _feePerOpCap(vaultStorage);
    }

    function gasBudgetDailyLimit(VaultStorage storage vaultStorage) external view returns (uint256) {
        return _dailyLimit(vaultStorage);
    }

    function gasBudgetRemaining(VaultStorage storage vaultStorage) external view returns (uint256) {
        uint256 limit = uint256(_dailyLimit(vaultStorage)) * 1e18;
        if (vaultStorage.gasBudgetDay != uint64(block.timestamp / 1 days)) return limit;
        uint256 spent = vaultStorage.gasSpentToday;
        return spent >= limit ? 0 : limit - spent;
    }

    function payActivationFee(VaultStorage storage vaultStorage, address stableCoinAddress, uint256 amount)
        external
        onlyInitialized(vaultStorage)
    {
        if (!IBittyV1Guard(BITTY_GUARD).isStableCoinRegistered(stableCoinAddress)) {
            revert PaymentNotStableCoin();
        }
        uint256 value =
            Math.mulDiv(amount, 1e18, 10 ** IERC20Metadata(stableCoinAddress).decimals(), Math.Rounding.Ceil);
        if (value > uint256(MAX_FEE_PER_OP) * 1e18) revert FeeExceedsPerOpCap();
        if (IERC20(stableCoinAddress).balanceOf(address(this)) < amount) revert InsufficientBalance();

        IERC20(stableCoinAddress).safeTransfer(BITTY_FEE_COLLECTOR, amount);
        emit IBittyV1Owner.ActivationFeePaid(stableCoinAddress, amount);
    }

    function gaslessCoinAllowed(VaultStorage storage vaultStorage, address coin) public view returns (bool) {
        return vaultStorage.gaslessStableCoins.contains(coin);
    }

    function payRelayerFee(VaultStorage storage vaultStorage, address stableCoinAddress, uint256 amount)
        external
        onlyInitialized(vaultStorage)
    {
        if (amount == 0) revert AmountIsZero();
        if (vaultStorage.renounced) revert OnlyImmutablePayableAfterRenounce();
        if (!gaslessCoinAllowed(vaultStorage, stableCoinAddress)) revert PaymentNotStableCoin();

        uint256 value =
            Math.mulDiv(amount, 1e18, 10 ** IERC20Metadata(stableCoinAddress).decimals(), Math.Rounding.Ceil);

        if (value > uint256(_feePerOpCap(vaultStorage)) * 1e18) revert FeeExceedsPerOpCap();

        uint64 today = uint64(block.timestamp / 1 days);
        uint256 spent = (vaultStorage.gasBudgetDay == today ? uint256(vaultStorage.gasSpentToday) : 0) + value;
        uint256 limit = uint256(_dailyLimit(vaultStorage)) * 1e18;
        if (spent > limit) revert GasBudgetExceeded();

        vaultStorage.gasBudgetDay = today;
        vaultStorage.gasSpentToday = uint96(spent);

        IERC20(stableCoinAddress).safeTransfer(BITTY_FEE_COLLECTOR, amount);
        emit IBittyV1Owner.RelayerFeePaid(stableCoinAddress, amount, spent, limit - spent);
    }

    function _processSendBatch(
        VaultStorage storage vaultStorage,
        address[] memory recipients,
        address[] memory assets,
        uint256[] memory amounts,
        bool execute,
        bool enforceOwnerSendWindow
    ) private {
        uint256 length = recipients.length;
        if (length == 0) revert EmptyArray();
        if (assets.length != length || amounts.length != length) revert ArrayLengthMismatch();

        _validateSendBatch(vaultStorage, recipients, assets, amounts, execute, enforceOwnerSendWindow);

        if (!execute) return;

        for (uint256 i = 0; i < length; i++) {
            _payOut(vaultStorage, assets[i], amounts[i], recipients[i]);
        }
    }

    function _validateSendBatch(
        VaultStorage storage vaultStorage,
        address[] memory recipients,
        address[] memory assets,
        uint256[] memory amounts,
        bool execute,
        bool enforceOwnerSendWindow
    ) private {
        uint64 cap = _effective(vaultStorage.riskConfig.maxSendValue);
        bool requireStable = cap != 0;

        uint256 totalStableValue;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert AddressZero();
            if (amounts[i] == 0) revert AmountIsZero();
            if (requireStable) {
                if (!stableCoinAllowed(vaultStorage, assets[i])) revert PaymentNotStableCoin();
                uint256 scale = 10 ** IERC20Metadata(assets[i]).decimals();
                totalStableValue += Math.mulDiv(amounts[i], 1e18, scale, Math.Rounding.Ceil);
                if (cap != 0 && totalStableValue > uint256(cap) * 1e18) revert PaymentExceedsRiskCap();
            }
        }

        if (execute && enforceOwnerSendWindow) {
            _checkOwnerSendWindow(vaultStorage, totalStableValue, cap);
        }
    }

    function _checkOwnerSendWindow(VaultStorage storage vaultStorage, uint256 batchStableValue, uint64 cap) private {
        if (cap == 0) return;
        uint64 window = _effective(vaultStorage.riskConfig.maxSendInterval);
        if (window == 0) return;

        uint64 periodStart = vaultStorage.ownerSendPeriodStart;
        uint256 sent = vaultStorage.ownerSentInPeriod;

        if (periodStart == 0 || block.timestamp >= uint256(periodStart) + window) {
            periodStart = uint64(block.timestamp);
            sent = 0;
        }

        uint256 total = sent + batchStableValue;
        if (total > uint256(cap) * 1e18) {
            revert PaymentExceedsPeriodLimit();
        }

        vaultStorage.ownerSendPeriodStart = periodStart;
        vaultStorage.ownerSentInPeriod = uint128(total);
    }

    function send(
        VaultStorage storage vaultStorage,
        address[] memory recipients,
        address[] memory assets,
        uint256[] memory amounts
    ) external onlyInitialized(vaultStorage) {
        _processSendBatch(vaultStorage, recipients, assets, amounts, true, true);
    }

    function proposeSend(
        VaultStorage storage vaultStorage,
        address[] memory recipients,
        address[] memory assets,
        uint256[] memory amounts,
        address sender
    ) external onlyInitialized(vaultStorage) returns (uint256 id) {
        _processSendBatch(vaultStorage, recipients, assets, amounts, false, false);
        id = vaultStorage.nextPendingSendId++;
        PendingSend storage ps = vaultStorage.pendingSends[id];
        ps.proposer = sender;
        ps.recipients = recipients;
        ps.assets = assets;
        ps.amounts = amounts;
        emit IBittyV1PayoutOperator.SendProposed(id, sender, recipients, assets, amounts);
    }

    function reviewSends(
        VaultStorage storage vaultStorage,
        uint256[] calldata approveIds,
        uint256[] calldata cancelIds,
        address sender
    ) external onlyInitialized(vaultStorage) {
        for (uint256 i; i < approveIds.length; ++i) {
            _approveSend(vaultStorage, approveIds[i]);
        }
        for (uint256 i; i < cancelIds.length; ++i) {
            _cancelSend(vaultStorage, cancelIds[i], true, sender);
        }
        if (approveIds.length > 0) emit IBittyV1Owner.SendsApproved(approveIds);
        if (cancelIds.length > 0) emit IBittyV1PayoutOperator.SendsCancelled(cancelIds);
    }

    function cancelSends(VaultStorage storage vaultStorage, uint256[] calldata ids, bool byOwner, address sender)
        external
        onlyInitialized(vaultStorage)
    {
        for (uint256 i; i < ids.length; ++i) {
            _cancelSend(vaultStorage, ids[i], byOwner, sender);
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.SendsCancelled(ids);
    }

    function _approveSend(VaultStorage storage vaultStorage, uint256 id) private {
        PendingSend memory ps = vaultStorage.pendingSends[id];
        if (ps.proposer == address(0)) {
            revert PendingSendNotFound();
        }
        delete vaultStorage.pendingSends[id];
        _processSendBatch(vaultStorage, ps.recipients, ps.assets, ps.amounts, true, false);
    }

    function _cancelSend(VaultStorage storage vaultStorage, uint256 id, bool byOwner, address sender) private {
        PendingSend memory ps = vaultStorage.pendingSends[id];
        if (ps.proposer == address(0)) {
            revert PendingSendNotFound();
        }
        if (!byOwner && ps.proposer != sender) {
            revert NotProposalOwner();
        }
        delete vaultStorage.pendingSends[id];
    }

    function addScheduledPaymentOne(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment calldata scheduledPayment,
        bool byOwner,
        address sender
    ) external onlyInitialized(vaultStorage) returns (uint256 id) {
        uint64 protection = _effective(vaultStorage.riskConfig.newPaymentProtection);
        id = _addScheduledPayment(
            vaultStorage,
            scheduledPayment,
            byOwner,
            _protectionDeadline(protection),
            _immutableLockDeadlineFromWindow(protection),
            sender
        );
        emit IBittyV1PayoutOperator.ScheduledPaymentAdded(id, scheduledPayment);
    }

    function addWhitelistedRecipientOne(
        VaultStorage storage vaultStorage,
        address recipient,
        address allowedAsset,
        bool byOwner,
        address sender
    ) external onlyInitialized(vaultStorage) returns (uint256 id) {
        uint256 deadline = _protectionDeadline(_effective(vaultStorage.riskConfig.newPaymentProtection));
        id = _addWhitelistedRecipient(vaultStorage, recipient, allowedAsset, byOwner, deadline, sender);
        emit IBittyV1PayoutOperator.WhitelistedRecipientSet(id, recipient, allowedAsset);
    }

    function approveSendOne(VaultStorage storage vaultStorage, uint256 id) external onlyInitialized(vaultStorage) {
        _approveSend(vaultStorage, id);
        emit IBittyV1Owner.SendApproved(id);
    }

    function payScheduledOne(VaultStorage storage vaultStorage, uint256 id, address sender)
        external
        onlyInitialized(vaultStorage)
    {
        (bool skipped, address addr, address asset, uint256 paid, uint256 count) =
            _payScheduledById(vaultStorage, id, sender);
        if (!skipped) emit IBittyV1Vault.ScheduledPaymentPaid(id, addr, asset, paid, count);
    }

    function sendToWhitelistedRecipientOne(VaultStorage storage vaultStorage, uint256 id, address asset, uint256 amount)
        external
        onlyInitialized(vaultStorage)
    {
        address recipient = _sendToWhitelistedRecipient(vaultStorage, id, asset, amount);
        emit IBittyV1Owner.WhitelistedRecipientPaid(id, recipient, asset, amount);
    }

    function _validateSendOne(
        VaultStorage storage vaultStorage,
        address recipient,
        address asset,
        uint256 amount,
        bool enforceOwnerSendWindow
    ) private {
        if (recipient == address(0)) revert AddressZero();
        if (amount == 0) revert AmountIsZero();

        uint64 cap = _effective(vaultStorage.riskConfig.maxSendValue);
        uint256 stableValue;
        if (cap != 0) {
            if (!stableCoinAllowed(vaultStorage, asset)) revert PaymentNotStableCoin();
            stableValue = Math.mulDiv(amount, 1e18, 10 ** IERC20Metadata(asset).decimals(), Math.Rounding.Ceil);
            if (stableValue > uint256(cap) * 1e18) revert PaymentExceedsRiskCap();
        }
        if (enforceOwnerSendWindow) _checkOwnerSendWindow(vaultStorage, stableValue, cap);
    }

    function sendOne(VaultStorage storage vaultStorage, address recipient, address asset, uint256 amount)
        external
        onlyInitialized(vaultStorage)
    {
        _validateSendOne(vaultStorage, recipient, asset, amount, true);
        _payOut(vaultStorage, asset, amount, recipient);
    }

    function proposeSendOne(
        VaultStorage storage vaultStorage,
        address recipient,
        address asset,
        uint256 amount,
        address sender
    ) external onlyInitialized(vaultStorage) returns (uint256 id) {
        _validateSendOne(vaultStorage, recipient, asset, amount, false);
        id = vaultStorage.nextPendingSendId++;
        PendingSend storage ps = vaultStorage.pendingSends[id];
        ps.proposer = sender;
        ps.recipients.push(recipient);
        ps.assets.push(asset);
        ps.amounts.push(amount);
        emit IBittyV1PayoutOperator.SendProposed(id, sender, ps.recipients, ps.assets, ps.amounts);
    }

    function cancelSendOne(VaultStorage storage vaultStorage, uint256 id, bool byOwner, address sender)
        external
        onlyInitialized(vaultStorage)
    {
        _cancelSend(vaultStorage, id, byOwner, sender);
        emit IBittyV1PayoutOperator.SendCancelled(id);
    }

    function _addScheduledPayment(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment calldata scheduledPayment,
        bool byOwner,
        uint256 protectionDeadline,
        uint256 immutableDeadline,
        address sender
    ) private returns (uint256 id) {
        if (scheduledPayment.startTimestamp < block.timestamp) {
            revert ScheduledPaymentStartTimestampInPast();
        }
        _checkScheduledPayment(scheduledPayment);
        id = ++vaultStorage.nextScheduledPaymentId;
        vaultStorage.scheduledPayments[id] = scheduledPayment;
        uint256 effectiveAt = protectionDeadline;
        if (!byOwner) {
            vaultStorage.scheduledPaymentPendingProposer[id] = sender;
        } else if (scheduledPayment.isImmutable) {
            effectiveAt = immutableDeadline;
        }
        vaultStorage.scheduledPaymentEffectiveAt[id] = effectiveAt;
    }

    function updateScheduledPayments(
        VaultStorage storage vaultStorage,
        uint256[] calldata ids,
        IBittyV1Vault.ScheduledPayment[] calldata scheduledPayments,
        bool byOwner,
        address sender
    ) external onlyInitialized(vaultStorage) {
        if (ids.length != scheduledPayments.length) revert ArrayLengthMismatch();
        uint64 protection = _effective(vaultStorage.riskConfig.newPaymentProtection);
        uint256 protectionDeadline = _protectionDeadline(protection);
        uint256 immutableDeadline = _immutableLockDeadlineFromWindow(protection);
        for (uint256 i; i < ids.length; ++i) {
            _updateScheduledPayment(
                vaultStorage, ids[i], scheduledPayments[i], byOwner, protectionDeadline, immutableDeadline, sender
            );
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.ScheduledPaymentsUpdated(ids, scheduledPayments);
    }

    function _updateScheduledPayment(
        VaultStorage storage vaultStorage,
        uint256 id,
        IBittyV1Vault.ScheduledPayment calldata scheduledPayment,
        bool byOwner,
        uint256 protectionDeadline,
        uint256 immutableDeadline,
        address sender
    ) private {
        if (scheduledPayment.startTimestamp < block.timestamp) {
            revert ScheduledPaymentStartTimestampInPast();
        }
        IBittyV1Vault.ScheduledPayment memory existing = vaultStorage.scheduledPayments[id];
        if (existing.recipient == address(0)) {
            revert ScheduledPaymentNotFound();
        }
        if (existing.isImmutable) {
            revert ScheduledPaymentImmutable();
        }
        if (byOwner) {
            delete vaultStorage.scheduledPaymentPendingProposer[id];
        } else if (vaultStorage.scheduledPaymentPendingProposer[id] != sender) {
            revert NotProposalOwner();
        }
        _checkScheduledPayment(scheduledPayment);
        vaultStorage.scheduledPayments[id] = scheduledPayment;
        uint256 effectiveAt = protectionDeadline;
        if (byOwner && scheduledPayment.isImmutable) {
            effectiveAt = immutableDeadline;
        }
        vaultStorage.scheduledPaymentEffectiveAt[id] = effectiveAt;
    }

    function reviewScheduledPayments(
        VaultStorage storage vaultStorage,
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds,
        address sender
    ) external onlyInitialized(vaultStorage) {
        if (approveIds.length != expectedHashes.length) revert ArrayLengthMismatch();
        uint256 immutableDeadline = _immutableLockDeadline(vaultStorage);
        for (uint256 i; i < approveIds.length; ++i) {
            _approveScheduledPayment(vaultStorage, approveIds[i], expectedHashes[i], immutableDeadline);
        }
        for (uint256 i; i < cancelIds.length; ++i) {
            _removeScheduledPayment(vaultStorage, cancelIds[i], true, sender);
        }
        if (approveIds.length > 0) emit IBittyV1Owner.ScheduledPaymentsApproved(approveIds);
        if (cancelIds.length > 0) emit IBittyV1PayoutOperator.ScheduledPaymentsRemoved(cancelIds);
    }

    function _approveScheduledPayment(
        VaultStorage storage vaultStorage,
        uint256 id,
        bytes32 expectedHash,
        uint256 immutableDeadline
    ) private {
        IBittyV1Vault.ScheduledPayment memory scheduledPayment = vaultStorage.scheduledPayments[id];
        if (scheduledPayment.amount == 0) {
            revert ScheduledPaymentNotFound();
        }
        if (vaultStorage.scheduledPaymentPendingProposer[id] == address(0)) {
            revert NotPendingApproval();
        }
        if (keccak256(abi.encode(scheduledPayment)) != expectedHash) {
            revert ScheduledPaymentContentMismatch();
        }
        delete vaultStorage.scheduledPaymentPendingProposer[id];
        if (scheduledPayment.isImmutable) {
            vaultStorage.scheduledPaymentEffectiveAt[id] = immutableDeadline;
        }
    }

    function _checkScheduledPayment(IBittyV1Vault.ScheduledPayment calldata scheduledPayment) internal view {
        if (scheduledPayment.recipient == address(0)) {
            revert AddressZero();
        }
        if (scheduledPayment.assetAddress != address(0) && scheduledPayment.assetAddress.code.length == 0) {
            revert AssetAddressNotContract();
        }
        if (scheduledPayment.amount == 0) {
            revert AmountIsZero();
        }
        if (scheduledPayment.remainingPaymentCount == 0) {
            revert ScheduledPaymentPaymentCountZero();
        }
    }

    function removeScheduledPayments(
        VaultStorage storage vaultStorage,
        uint256[] calldata ids,
        bool byOwner,
        address sender
    ) external onlyInitialized(vaultStorage) {
        for (uint256 i; i < ids.length; ++i) {
            _removeScheduledPayment(vaultStorage, ids[i], byOwner, sender);
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.ScheduledPaymentsRemoved(ids);
    }

    function _removeScheduledPayment(VaultStorage storage vaultStorage, uint256 id, bool byOwner, address sender)
        private
    {
        if (!byOwner && vaultStorage.scheduledPaymentPendingProposer[id] != sender) {
            revert NotProposalOwner();
        }
        if (_isLockedImmutable(vaultStorage, id)) {
            revert ImmutableScheduledPaymentLocked();
        }
        delete vaultStorage.scheduledPayments[id];
        delete vaultStorage.scheduledPaymentPendingProposer[id];
        delete vaultStorage.lastReceiveTimestamps[id];
        delete vaultStorage.scheduledPaymentEffectiveAt[id];
    }

    function prepareRenounce(VaultStorage storage vaultStorage, uint256 rescueScheduledPaymentId)
        external
        onlyInitialized(vaultStorage)
    {
        if (!_isLockedImmutable(vaultStorage, rescueScheduledPaymentId)) {
            revert NoRescueTarget();
        }
        vaultStorage.renounced = true;
    }

    function _isLockedImmutable(VaultStorage storage vaultStorage, uint256 id) internal view returns (bool) {
        IBittyV1Vault.ScheduledPayment storage p = vaultStorage.scheduledPayments[id];
        return p.isImmutable && p.remainingPaymentCount > 0
            && vaultStorage.scheduledPaymentPendingProposer[id] == address(0)
            && block.timestamp >= vaultStorage.scheduledPaymentEffectiveAt[id];
    }

    function updatePaymentRisk(VaultStorage storage vaultStorage, IBittyV1Owner.PaymentRisk calldata paymentRisk)
        external
        onlyInitialized(vaultStorage)
    {
        uint64 timelock = _effective(vaultStorage.riskConfig.changeTimelock);
        if (paymentRisk.newPaymentProtection != UNCHANGED) {
            if (paymentRisk.newPaymentProtection > MAX_PAYMENT_PROTECTION) {
                revert PaymentProtectionTooLong();
            }
            _setHigherSafer(vaultStorage.riskConfig.newPaymentProtection, paymentRisk.newPaymentProtection, timelock);
        }
        if (paymentRisk.maxSendValue != UNCHANGED) {
            _setCap(vaultStorage.riskConfig.maxSendValue, paymentRisk.maxSendValue, timelock);
        }
        if (paymentRisk.maxSendInterval != UNCHANGED) {
            _setHigherSafer(vaultStorage.riskConfig.maxSendInterval, paymentRisk.maxSendInterval, timelock);
        }
        if (paymentRisk.changeTimelock != UNCHANGED) {
            _setHigherSafer(vaultStorage.riskConfig.changeTimelock, paymentRisk.changeTimelock, timelock);
        }
        emit IBittyV1Owner.PaymentRiskUpdated(paymentRisk);
    }

    function updatePayoutOperatorOne(VaultStorage storage vaultStorage, address payoutOperator, bool add)
        external
        onlyInitialized(vaultStorage)
    {
        if (add) {
            if (payoutOperator == address(0)) revert AddressZero();
            if (!vaultStorage.payoutOperators.add(payoutOperator)) revert PayoutOperatorAlreadyRegistered();
        } else {
            if (!vaultStorage.payoutOperators.remove(payoutOperator)) revert PayoutOperatorNotFound();
        }
    }

    function getPayoutOperators(VaultStorage storage vaultStorage) external view returns (address[] memory) {
        return vaultStorage.payoutOperators.values();
    }

    function isPayoutOperator(VaultStorage storage vaultStorage, address account) external view returns (bool) {
        return vaultStorage.payoutOperators.contains(account);
    }

    function getRiskConfig(VaultStorage storage vaultStorage)
        external
        view
        returns (uint64 newPaymentProtection, uint64 maxSendValue, uint64 changeTimelock, uint64 maxSendInterval)
    {
        RiskConfig storage r = vaultStorage.riskConfig;
        return (
            _effective(r.newPaymentProtection),
            _effective(r.maxSendValue),
            _effective(r.changeTimelock),
            _effective(r.maxSendInterval)
        );
    }

    function _protectionDeadline(uint256 protection) private view returns (uint256) {
        return protection == 0 ? 0 : block.timestamp + protection;
    }

    function _immutableLockDeadline(VaultStorage storage vaultStorage) private view returns (uint256) {
        return _immutableLockDeadlineFromWindow(_effective(vaultStorage.riskConfig.newPaymentProtection));
    }

    function _immutableLockDeadlineFromWindow(uint64 window) private view returns (uint256) {
        return block.timestamp + window;
    }

    function _requireProtectionElapsed(uint256 effectiveAt) private view {
        if (block.timestamp < effectiveAt) {
            revert ProtectionPeriodNotEnded();
        }
    }

    function _addWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        address recipient,
        address allowedAsset,
        bool byOwner,
        uint256 protectionDeadline,
        address sender
    ) private returns (uint256 id) {
        if (recipient == address(0)) {
            revert AddressZero();
        }
        id = ++vaultStorage.nextWhitelistedRecipientId;
        vaultStorage.whitelistedRecipients[id] =
            IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset});
        if (!byOwner) {
            vaultStorage.whitelistedRecipientPendingProposer[id] = sender;
        }
        vaultStorage.whitelistedRecipientEffectiveAt[id] = protectionDeadline;
    }

    function updateWhitelistedRecipients(
        VaultStorage storage vaultStorage,
        uint256[] calldata ids,
        address[] calldata recipients,
        address[] calldata allowedAssets,
        bool byOwner,
        address sender
    ) external onlyInitialized(vaultStorage) {
        if (ids.length != recipients.length || recipients.length != allowedAssets.length) {
            revert ArrayLengthMismatch();
        }
        uint256 protectionDeadline = _protectionDeadline(_effective(vaultStorage.riskConfig.newPaymentProtection));
        for (uint256 i; i < ids.length; ++i) {
            _updateWhitelistedRecipient(
                vaultStorage, ids[i], recipients[i], allowedAssets[i], byOwner, protectionDeadline, sender
            );
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.WhitelistedRecipientsSet(ids, recipients, allowedAssets);
    }

    function _updateWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        uint256 id,
        address recipient,
        address allowedAsset,
        bool byOwner,
        uint256 protectionDeadline,
        address sender
    ) private {
        if (recipient == address(0)) {
            revert AddressZero();
        }
        if (vaultStorage.whitelistedRecipients[id].recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        if (byOwner) {
            delete vaultStorage.whitelistedRecipientPendingProposer[id];
        } else if (vaultStorage.whitelistedRecipientPendingProposer[id] != sender) {
            revert NotProposalOwner();
        }
        vaultStorage.whitelistedRecipients[id] =
            IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset});
        vaultStorage.whitelistedRecipientEffectiveAt[id] = protectionDeadline;
    }

    function reviewWhitelistedRecipients(
        VaultStorage storage vaultStorage,
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds,
        address sender
    ) external onlyInitialized(vaultStorage) {
        if (approveIds.length != expectedHashes.length) revert ArrayLengthMismatch();
        for (uint256 i; i < approveIds.length; ++i) {
            _approveWhitelistedRecipient(vaultStorage, approveIds[i], expectedHashes[i]);
        }
        for (uint256 i; i < cancelIds.length; ++i) {
            _removeWhitelistedRecipient(vaultStorage, cancelIds[i], true, sender);
        }
        if (approveIds.length > 0) emit IBittyV1Owner.WhitelistedRecipientsApproved(approveIds);
        if (cancelIds.length > 0) emit IBittyV1PayoutOperator.WhitelistedRecipientsRemoved(cancelIds);
    }

    function _approveWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, bytes32 expectedHash) private {
        IBittyV1Vault.WhitelistedRecipient memory recipient = vaultStorage.whitelistedRecipients[id];
        if (recipient.recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        if (vaultStorage.whitelistedRecipientPendingProposer[id] == address(0)) {
            revert NotPendingApproval();
        }
        if (keccak256(abi.encode(recipient)) != expectedHash) {
            revert WhitelistedRecipientContentMismatch();
        }
        delete vaultStorage.whitelistedRecipientPendingProposer[id];
    }

    function removeWhitelistedRecipients(
        VaultStorage storage vaultStorage,
        uint256[] calldata ids,
        bool byOwner,
        address sender
    ) external onlyInitialized(vaultStorage) {
        for (uint256 i; i < ids.length; ++i) {
            _removeWhitelistedRecipient(vaultStorage, ids[i], byOwner, sender);
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.WhitelistedRecipientsRemoved(ids);
    }

    function _removeWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, bool byOwner, address sender)
        private
    {
        address recipient = vaultStorage.whitelistedRecipients[id].recipient;
        if (recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        if (!byOwner && vaultStorage.whitelistedRecipientPendingProposer[id] != sender) {
            revert NotProposalOwner();
        }
        delete vaultStorage.whitelistedRecipients[id];
        delete vaultStorage.whitelistedRecipientPendingProposer[id];
        delete vaultStorage.whitelistedRecipientEffectiveAt[id];
    }

    function _sendToWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, address asset, uint256 amount)
        private
        returns (address recipient)
    {
        if (amount == 0) {
            revert AmountIsZero();
        }
        IBittyV1Vault.WhitelistedRecipient memory entry = vaultStorage.whitelistedRecipients[id];
        if (entry.recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        if (vaultStorage.whitelistedRecipientPendingProposer[id] != address(0)) {
            revert PaymentNotApproved();
        }
        if (entry.allowedAsset != address(0) && asset != entry.allowedAsset) {
            revert WhitelistedRecipientAssetNotAllowed();
        }
        _requireProtectionElapsed(vaultStorage.whitelistedRecipientEffectiveAt[id]);
        _payOut(vaultStorage, asset, amount, entry.recipient);
        recipient = entry.recipient;
    }

    function getWhitelistedRecipients(VaultStorage storage vaultStorage, uint256[] calldata ids)
        external
        view
        returns (address[] memory recipients, address[] memory allowedAssets)
    {
        recipients = new address[](ids.length);
        allowedAssets = new address[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            IBittyV1Vault.WhitelistedRecipient memory entry = vaultStorage.whitelistedRecipients[ids[i]];
            recipients[i] = entry.recipient;
            allowedAssets[i] = entry.allowedAsset;
        }
    }

    function payScheduled(VaultStorage storage vaultStorage, uint256[] calldata ids, address sender)
        external
        onlyInitialized(vaultStorage)
    {
        uint256 n = ids.length;
        uint256[] memory paidIds = new uint256[](n);
        address[] memory addrs = new address[](n);
        address[] memory assetsOut = new address[](n);
        uint256[] memory amountsOut = new uint256[](n);
        uint256[] memory counts = new uint256[](n);
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            (bool skipped, address addr, address asset, uint256 amount, uint256 count) =
                _payScheduledById(vaultStorage, ids[i], sender);
            if (skipped) continue;
            paidIds[paid] = ids[i];
            addrs[paid] = addr;
            assetsOut[paid] = asset;
            amountsOut[paid] = amount;
            counts[paid] = count;
            ++paid;
        }
        assembly ("memory-safe") {
            mstore(paidIds, paid)
            mstore(addrs, paid)
            mstore(assetsOut, paid)
            mstore(amountsOut, paid)
            mstore(counts, paid)
        }
        if (paid > 0) {
            emit IBittyV1Vault.ScheduledPaymentsPaid(paidIds, addrs, assetsOut, amountsOut, counts);
        }
    }

    function _payScheduledById(VaultStorage storage vaultStorage, uint256 id, address sender)
        private
        returns (
            bool skipped,
            address recipient,
            address assetAddress,
            uint256 paidAmount,
            uint256 remainingPaymentCount
        )
    {
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[id];
        if (scheduledPayment.trigger != address(0) && sender != scheduledPayment.trigger) {
            revert ScheduledPaymentTriggerError();
        }
        return _payScheduled(vaultStorage, scheduledPayment, id, scheduledPayment.amount);
    }

    function payScheduledAmount(VaultStorage storage vaultStorage, uint256 id, uint256 amount, address sender)
        external
        onlyInitialized(vaultStorage)
    {
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[id];
        if (scheduledPayment.amount < amount) {
            revert PayMoreThanScheduledPaymentAmount();
        }
        if (scheduledPayment.trigger == address(0)) {
            revert PayScheduledPaymentAmountTriggerEmpty();
        }
        if (sender != scheduledPayment.trigger) {
            revert ScheduledPaymentTriggerError();
        }
        (bool skipped, address addr, address asset, uint256 paid, uint256 count) =
            _payScheduled(vaultStorage, scheduledPayment, id, amount);
        if (!skipped) emit IBittyV1Vault.ScheduledPaymentPaid(id, addr, asset, paid, count);
    }

    function scheduledPaymentAsset(VaultStorage storage vaultStorage, uint256 id) external view returns (address) {
        return vaultStorage.scheduledPayments[id].assetAddress;
    }

    function _payScheduled(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment storage scheduledPayment,
        uint256 id,
        uint256 payAmount
    )
        internal
        returns (
            bool skipped,
            address recipient,
            address assetAddress,
            uint256 paidAmount,
            uint256 remainingPaymentCount
        )
    {
        if (_accrueScheduledPayment(vaultStorage, scheduledPayment, id, false)) {
            return (true, address(0), address(0), 0, 0);
        }
        paidAmount = _transferMoney(
            vaultStorage,
            scheduledPayment.assetAddress,
            payAmount,
            scheduledPayment.recipient,
            scheduledPayment.payWithInsufficientBalance
        );
        recipient = scheduledPayment.recipient;
        assetAddress = scheduledPayment.assetAddress;
        remainingPaymentCount = scheduledPayment.remainingPaymentCount;
    }

    function _accrueScheduledPayment(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment storage scheduledPayment,
        uint256 id,
        bool fromPosition
    ) internal returns (bool skipped) {
        if (scheduledPayment.amount == 0) {
            revert ScheduledPaymentNotFound();
        }
        if (vaultStorage.renounced && !_isLockedImmutable(vaultStorage, id)) {
            revert OnlyImmutablePayableAfterRenounce();
        }
        if (vaultStorage.scheduledPaymentPendingProposer[id] != address(0)) {
            revert PaymentNotApproved();
        }
        if (scheduledPayment.remainingPaymentCount == 0) {
            revert ScheduledPaymentPaymentCountZero();
        }
        if (scheduledPayment.startTimestamp > block.timestamp) {
            revert ScheduledPaymentNotStartYet();
        }
        if (
            scheduledPayment.paymentInterval != 0 && vaultStorage.lastReceiveTimestamps[id] > 0
                && block.timestamp - vaultStorage.lastReceiveTimestamps[id] < scheduledPayment.paymentInterval
        ) {
            revert ScheduledPaymentInInterval();
        }
        _requireProtectionElapsed(vaultStorage.scheduledPaymentEffectiveAt[id]);

        if (!fromPosition && scheduledPayment.payWithInsufficientBalance) {
            address balanceToken =
                scheduledPayment.assetAddress == address(0) ? vaultStorage.weth : scheduledPayment.assetAddress;
            if (IERC20(balanceToken).balanceOf(address(this)) == 0) {
                return true;
            }
        }

        vaultStorage.lastReceiveTimestamps[id] = block.timestamp;

        if (scheduledPayment.remainingPaymentCount != type(uint256).max) {
            scheduledPayment.remainingPaymentCount = scheduledPayment.remainingPaymentCount - 1;
        }
    }

    function _transferMoney(
        VaultStorage storage vaultStorage,
        address erc20Address,
        uint256 amount,
        address recipient,
        bool payWithInsufficientBalance
    ) internal returns (uint256 paidAmount) {
        address balanceToken = erc20Address == address(0) ? vaultStorage.weth : erc20Address;
        uint256 balance = IERC20(balanceToken).balanceOf(address(this));
        if (!payWithInsufficientBalance && balance < amount) {
            revert InsufficientBalance();
        }
        paidAmount = balance < amount ? balance : amount;
        _payOut(vaultStorage, erc20Address, paidAmount, recipient);
    }

    function _payOut(VaultStorage storage vaultStorage, address asset, uint256 amount, address to) internal {
        if (amount == 0) {
            return;
        }
        if (asset == address(0)) {
            bool locked;
            assembly ("memory-safe") {
                locked := tload(_PAYING_ETH_SLOT)
            }
            if (locked) {
                revert ReentrantCall();
            }
            assembly ("memory-safe") {
                tstore(_PAYING_ETH_SLOT, 1)
            }
            WETH(payable(vaultStorage.weth)).withdraw(amount);
            (bool ok,) = to.call{value: amount}("");
            if (!ok) {
                revert TransferFailed();
            }
            assembly ("memory-safe") {
                tstore(_PAYING_ETH_SLOT, 0)
            }
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function seedMinimalAllowList(VaultStorage storage vaultStorage, address weth) external {
        vaultStorage.assets.add(weth);
        address[] memory guardStableCoins = IBittyV1Guard(BITTY_GUARD).getStableCoins();
        for (uint256 i = 0; i < guardStableCoins.length; i++) {
            vaultStorage.stableCoins.add(guardStableCoins[i]);
            vaultStorage.gaslessStableCoins.add(guardStableCoins[i]);
        }
    }

    function addAsset(VaultStorage storage vaultStorage, address assetAddress) external onlyInitialized(vaultStorage) {
        if (vaultStorage.addingAssetsDisabled) {
            revert AddingAssetsDisabled();
        }
        _addAsset(vaultStorage, assetAddress);
    }

    function addAssets(VaultStorage storage vaultStorage, address[] memory assetAddresses)
        external
        onlyInitialized(vaultStorage)
    {
        if (vaultStorage.addingAssetsDisabled) {
            revert AddingAssetsDisabled();
        }
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            _addAsset(vaultStorage, assetAddresses[i]);
        }
    }

    function _addAsset(VaultStorage storage vaultStorage, address assetAddress) private {
        if (IBittyV1Guard(BITTY_GUARD).isAssetRegistered(assetAddress)) {
            vaultStorage.assets.add(assetAddress);
        } else if (IBittyV1Guard(BITTY_GUARD).isStableCoinRegistered(assetAddress)) {
            vaultStorage.stableCoins.add(assetAddress);
        } else {
            revert NotRegistered();
        }
    }

    function disableAddingAssets(VaultStorage storage vaultStorage) external onlyInitialized(vaultStorage) {
        vaultStorage.addingAssetsDisabled = true;
    }

    function removeAssets(VaultStorage storage vaultStorage, address[] memory assetAddresses)
        external
        onlyInitialized(vaultStorage)
    {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (vaultStorage.assets.contains(assetAddresses[i])) {
                vaultStorage.assets.remove(assetAddresses[i]);
            } else if (vaultStorage.stableCoins.contains(assetAddresses[i])) {
                vaultStorage.stableCoins.remove(assetAddresses[i]);
            } else {
                revert NotRegistered();
            }
        }
    }

    function getAssets(VaultStorage storage vaultStorage) external view returns (address[] memory) {
        return vaultStorage.assets.values();
    }

    function getStableCoins(VaultStorage storage vaultStorage) external view returns (address[] memory) {
        return vaultStorage.stableCoins.values();
    }

    function assetAllowed(VaultStorage storage vaultStorage, address assetAddress) public view returns (bool) {
        return vaultStorage.assets.contains(assetAddress) || vaultStorage.stableCoins.contains(assetAddress);
    }

    function stableCoinAllowed(VaultStorage storage vaultStorage, address assetAddress) public view returns (bool) {
        return vaultStorage.stableCoins.contains(assetAddress);
    }

    function checkAsset(VaultStorage storage logicStorage, address assetAddress) external view {
        if (assetAllowed(logicStorage, assetAddress)) {
            return;
        }
        revert NotRegistered();
    }
}
