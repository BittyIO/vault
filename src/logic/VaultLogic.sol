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
    OnlyImmutablePayableAfterRenounce
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
import {
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
    ScheduledPaymentIntervalTooShort,
    AssetAddressNotContract,
    ProtectionPeriodNotEnded,
    ScheduledPaymentProtectionTooLong,
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
    RiskControlLevel
} from "../interfaces/IBittyV1Vault.sol";

library VaultLogic {
    // Upper to (~10 years) a close fund cap 10 years lock)
    uint64 constant MAX_SCHEDULED_PAYMENT_PROTECTION = 3650 days;

    uint64 constant STANDARD_RISK_TIMELOCK = 3 days;
    uint64 constant STANDARD_RISK_CAP = 10000;

    uint64 constant HIGH_RISK_TIMELOCK = 7 days;
    uint64 constant HIGH_RISK_CAP = 1000;

    // Sentinel in {updatePaymentRisk}: a field set to this is left unchanged (no storage access).
    uint256 constant UNCHANGED = type(uint256).max;

    using EnumerableSet for EnumerableSet.AddressSet;
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

    function initialize(VaultStorage storage vaultStorage, address guardAddress, RiskControlLevel level)
        external
        onlyNotInitialized(vaultStorage)
    {
        vaultStorage.guard = IBittyV1Guard(guardAddress);
        vaultStorage.riskConfig = _defaultRisk(level);
        vaultStorage.riskControlLevel = level;
        vaultStorage.isInitialized = true;
    }

    function getRiskControlLevel(VaultStorage storage vaultStorage) external view returns (RiskControlLevel) {
        return vaultStorage.riskControlLevel;
    }

    /**
     * @notice Hardcoded payment-risk defaults per level. `Zero` is all-zero (no controls, and a zero
     *         changeTimelock so any later change is instant); Standard and High seed the guardrails plus a
     *         loosening delay. Every value the owner may later change freely, but loosening waits changeTimelock.
     */
    function _defaultRisk(RiskControlLevel level) internal pure returns (RiskConfig memory c) {
        if (level == RiskControlLevel.Standard) {
            c.scheduledPaymentProtection.value = STANDARD_RISK_TIMELOCK;
            c.whitelistedProtection.value = STANDARD_RISK_TIMELOCK;
            c.maxSendValue.value = STANDARD_RISK_CAP;
            c.maxScheduledValue.value = STANDARD_RISK_CAP;
            c.maxWhitelistedValue.value = STANDARD_RISK_CAP;
            c.changeTimelock.value = STANDARD_RISK_TIMELOCK;
            c.maxSendInterval.value = STANDARD_RISK_TIMELOCK;
        } else if (level == RiskControlLevel.High) {
            c.scheduledPaymentProtection.value = HIGH_RISK_TIMELOCK;
            c.whitelistedProtection.value = HIGH_RISK_TIMELOCK;
            c.maxSendValue.value = HIGH_RISK_CAP;
            c.maxScheduledValue.value = HIGH_RISK_CAP;
            c.maxWhitelistedValue.value = HIGH_RISK_CAP;
            c.changeTimelock.value = HIGH_RISK_TIMELOCK;
            c.maxSendInterval.value = HIGH_RISK_TIMELOCK;
        }
    }

    /**
     * @notice Enforce a per-path payment risk cap. When `cap` is non-zero the payment must be a
     *         stablecoin whose amount is within `cap` whole tokens; `cap == 0` disables the check.
     */
    function _checkPaymentRiskCap(VaultStorage storage vaultStorage, uint64 cap, address asset, uint256 amount)
        private
        view
    {
        if (cap == 0) return;
        if (!vaultStorage.stableCoins.contains(asset)) revert PaymentNotStableCoin();
        if (amount > uint256(cap) * (10 ** IERC20Metadata(asset).decimals())) revert PaymentExceedsRiskCap();
    }

    function _effective(TimelockedValue storage tv) private view returns (uint64) {
        if (tv.pendingAt != 0 && block.timestamp >= tv.pendingAt) return tv.pending;
        return tv.value;
    }

    function _settle(TimelockedValue storage tv) private {
        if (tv.pendingAt != 0 && block.timestamp >= tv.pendingAt) {
            tv.value = tv.pending;
            tv.pending = 0;
            tv.pendingAt = 0;
        }
    }

    /**
     * @dev Loosening waits `timelock`; tightening is immediate.
     */
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

    /**
     * @dev Higher = safer for protection/timelock fields, so lowering is a loosening.
     */
    function _setHigherSafer(TimelockedValue storage tv, uint256 next, uint64 timelock) private {
        _settle(tv);
        uint64 n = uint64(next);
        _apply(tv, n, n < tv.value, timelock);
    }

    /**
     * @dev For caps, 0 = unrestricted; raising or clearing to 0 is a loosening.
     */
    function _setCap(TimelockedValue storage tv, uint256 next, uint64 timelock) private {
        _settle(tv);
        uint64 n = uint64(next);
        bool loosen = tv.value != 0 && (n == 0 || n > tv.value);
        _apply(tv, n, loosen, timelock);
    }

    /**
     * @dev Validates a batch in a single pass. Owner direct sends pass `enforceOwnerSendWindow` so the rolling
     *      maxSendValue / maxSendInterval quota applies; payout-operator proposals and approvals do not.
     */
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

    /**
     * @dev Split frame so locals don't share the stack with the payout loop (coverage build stack limit).
     */
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
                if (!vaultStorage.stableCoins.contains(assets[i])) revert PaymentNotStableCoin();
                uint256 scale = 10 ** IERC20Metadata(assets[i]).decimals();
                totalStableValue += Math.mulDiv(amounts[i], 1e18, scale, Math.Rounding.Ceil);
                if (cap != 0 && totalStableValue > uint256(cap) * 1e18) revert PaymentExceedsRiskCap();
            }
        }

        if (execute && enforceOwnerSendWindow) {
            _checkOwnerSendWindow(vaultStorage, totalStableValue, cap);
        }
    }

    /**
     * @notice Enforce the owner's rolling one-off send quota (maxSendValue per maxSendInterval).
     *         Resets the window when it elapses.
     */
    function _checkOwnerSendWindow(VaultStorage storage vaultStorage, uint256 batchStableValue, uint64 cap) private {
        if (cap == 0) return;
        uint64 window = _effective(vaultStorage.riskConfig.maxSendInterval);
        if (window == 0) return;

        uint128 periodStart = vaultStorage.ownerSendPeriodStart;
        uint256 sent = vaultStorage.ownerSentInPeriod;

        if (periodStart == 0 || block.timestamp >= periodStart + window) {
            periodStart = uint128(block.timestamp);
            sent = 0;
        }

        if (sent + batchStableValue > uint256(cap) * 1e18) {
            revert PaymentExceedsPeriodLimit();
        }

        vaultStorage.ownerSendPeriodStart = periodStart;
        vaultStorage.ownerSentInPeriod = sent + batchStableValue;
    }

    function send(
        VaultStorage storage vaultStorage,
        address[] memory recipients,
        address[] memory assets,
        uint256[] memory amounts
    ) external onlyInitialized(vaultStorage) {
        _processSendBatch(vaultStorage, recipients, assets, amounts, true, true);
    }

    /**
     * @notice Queue a payout-operator-proposed one-off send for owner approval. Access control
     *         (payout operator) is enforced by the facade.
     */
    function proposeSend(
        VaultStorage storage vaultStorage,
        address[] memory recipients,
        address[] memory assets,
        uint256[] memory amounts
    ) external onlyInitialized(vaultStorage) returns (uint256 id) {
        _processSendBatch(vaultStorage, recipients, assets, amounts, false, false);
        id = vaultStorage.nextPendingSendId++;
        PendingSend storage ps = vaultStorage.pendingSends[id];
        ps.proposer = msg.sender;
        ps.recipients = recipients;
        ps.assets = assets;
        ps.amounts = amounts;
        emit IBittyV1PayoutOperator.SendProposed(id, msg.sender, recipients, assets, amounts);
    }

    /**
     * @notice Owner: approve and/or cancel queued one-off sends in a single delegatecall (approves first).
     *         The initialized check runs once for the whole batch. Access control (owner-only) is enforced
     *         by the facade, so every cancel here is a privileged owner cancel.
     */
    function reviewSends(VaultStorage storage vaultStorage, uint256[] calldata approveIds, uint256[] calldata cancelIds)
        external
        onlyInitialized(vaultStorage)
    {
        for (uint256 i; i < approveIds.length; ++i) {
            _approveSend(vaultStorage, approveIds[i]);
        }
        for (uint256 i; i < cancelIds.length; ++i) {
            _cancelSend(vaultStorage, cancelIds[i], true);
        }
        // One event per batch instead of one per id.
        if (approveIds.length > 0) emit IBittyV1Owner.SendsApproved(approveIds);
        if (cancelIds.length > 0) emit IBittyV1PayoutOperator.SendsCancelled(cancelIds);
    }

    /**
     * @notice Cancel queued one-off sends. The owner may cancel any; a payout operator only its own.
     *         The initialized check runs once. Access control (owner-or-proposer) is enforced by the facade
     *         plus the per-item check.
     */
    function cancelSends(VaultStorage storage vaultStorage, uint256[] calldata ids, bool byOwner)
        external
        onlyInitialized(vaultStorage)
    {
        for (uint256 i; i < ids.length; ++i) {
            _cancelSend(vaultStorage, ids[i], byOwner);
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.SendsCancelled(ids);
    }

    /**
     * @dev Execute one queued send. Re-checks against the controls in force at approval time, so a
     *      tightening also binds an already-queued batch. The batched {SendsApproved} event is emitted by
     *      the caller.
     */
    function _approveSend(VaultStorage storage vaultStorage, uint256 id) private {
        PendingSend memory ps = vaultStorage.pendingSends[id];
        if (ps.proposer == address(0)) {
            revert PendingSendNotFound();
        }
        delete vaultStorage.pendingSends[id];
        _processSendBatch(vaultStorage, ps.recipients, ps.assets, ps.amounts, true, false);
    }

    function _cancelSend(VaultStorage storage vaultStorage, uint256 id, bool byOwner) private {
        PendingSend memory ps = vaultStorage.pendingSends[id];
        if (ps.proposer == address(0)) {
            revert PendingSendNotFound();
        }
        if (!byOwner && ps.proposer != msg.sender) {
            revert NotProposalOwner();
        }
        delete vaultStorage.pendingSends[id];
    }

    /**
     * @notice Add one or more scheduled payments. The initialized check, the risk cap, and both
     *         protection-window deadlines are read once for the whole batch, then applied per item.
     *         Access control (owner-or-payout-operator) is enforced by the facade.
     */
    function addScheduledPayments(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment[] calldata scheduledPayments,
        bool byOwner
    ) external onlyInitialized(vaultStorage) returns (uint256[] memory ids) {
        uint64 cap = _effective(vaultStorage.riskConfig.maxScheduledValue);
        uint64 protection = _effective(vaultStorage.riskConfig.scheduledPaymentProtection);
        uint256 protectionDeadline = _protectionDeadline(protection);
        uint256 immutableDeadline = _immutableLockDeadlineFromWindow(protection);
        ids = new uint256[](scheduledPayments.length);
        for (uint256 i; i < scheduledPayments.length; ++i) {
            ids[i] = _addScheduledPayment(
                vaultStorage, scheduledPayments[i], byOwner, cap, protectionDeadline, immutableDeadline
            );
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.ScheduledPaymentsAdded(ids, scheduledPayments);
    }

    function _addScheduledPayment(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment calldata scheduledPayment,
        bool byOwner,
        uint64 cap,
        uint256 protectionDeadline,
        uint256 immutableDeadline
    ) private returns (uint256 id) {
        if (scheduledPayment.startTimestamp < block.timestamp) {
            revert ScheduledPaymentStartTimestampInPast();
        }
        _checkScheduledPayment(scheduledPayment);
        _checkPaymentRiskCap(vaultStorage, cap, scheduledPayment.assetAddress, scheduledPayment.amount);
        id = ++vaultStorage.nextScheduledPaymentId;
        vaultStorage.scheduledPayments[id] = scheduledPayment;
        uint256 effectiveAt = protectionDeadline;
        // msg.sender (the proposing payment asset manager) survives the delegatecall from the facade.
        if (!byOwner) {
            vaultStorage.scheduledPaymentPendingProposer[id] = msg.sender;
        } else if (scheduledPayment.isImmutable) {
            // An owner-added immutable entry starts its permanent-lock window immediately.
            effectiveAt = immutableDeadline;
        }
        vaultStorage.scheduledPaymentEffectiveAt[id] = effectiveAt;
        // The batched {ScheduledPaymentsAdded} event is emitted by the caller.
    }

    /**
     * @notice Update one or more scheduled payments (ids[i] ← scheduledPayments[i]). The initialized check,
     *         risk cap, and protection-window deadlines are read once for the whole batch. Arrays must be
     *         equal length. Access control (owner-or-payout-operator) is enforced by the facade.
     */
    function updateScheduledPayments(
        VaultStorage storage vaultStorage,
        uint256[] calldata ids,
        IBittyV1Vault.ScheduledPayment[] calldata scheduledPayments,
        bool byOwner
    ) external onlyInitialized(vaultStorage) {
        if (ids.length != scheduledPayments.length) revert ArrayLengthMismatch();
        uint64 cap = _effective(vaultStorage.riskConfig.maxScheduledValue);
        uint64 protection = _effective(vaultStorage.riskConfig.scheduledPaymentProtection);
        uint256 protectionDeadline = _protectionDeadline(protection);
        uint256 immutableDeadline = _immutableLockDeadlineFromWindow(protection);
        for (uint256 i; i < ids.length; ++i) {
            _updateScheduledPayment(
                vaultStorage, ids[i], scheduledPayments[i], byOwner, cap, protectionDeadline, immutableDeadline
            );
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.ScheduledPaymentsUpdated(ids, scheduledPayments);
    }

    function _updateScheduledPayment(
        VaultStorage storage vaultStorage,
        uint256 id,
        IBittyV1Vault.ScheduledPayment calldata scheduledPayment,
        bool byOwner,
        uint64 cap,
        uint256 protectionDeadline,
        uint256 immutableDeadline
    ) private {
        if (scheduledPayment.startTimestamp < block.timestamp) {
            revert ScheduledPaymentStartTimestampInPast();
        }
        IBittyV1Vault.ScheduledPayment memory existing = vaultStorage.scheduledPayments[id];
        if (existing.scheduledPaymentAddress == address(0)) {
            revert ScheduledPaymentNotFound();
        }
        if (existing.isImmutable) {
            revert ScheduledPaymentImmutable();
        }
        if (byOwner) {
            // An owner edit vets the entry, so it approves any pending proposal.
            delete vaultStorage.scheduledPaymentPendingProposer[id];
        } else if (vaultStorage.scheduledPaymentPendingProposer[id] != msg.sender) {
            revert NotProposalOwner();
        }
        _checkScheduledPayment(scheduledPayment);
        _checkPaymentRiskCap(vaultStorage, cap, scheduledPayment.assetAddress, scheduledPayment.amount);
        vaultStorage.scheduledPayments[id] = scheduledPayment;
        uint256 effectiveAt = protectionDeadline;
        if (byOwner && scheduledPayment.isImmutable) {
            // An owner edit that makes a (necessarily still-mutable) entry immutable starts its
            // permanent-lock window fresh, so the irreversible change gets a full review period.
            effectiveAt = immutableDeadline;
        }
        vaultStorage.scheduledPaymentEffectiveAt[id] = effectiveAt;
        // The batched {ScheduledPaymentsUpdated} event is emitted by the caller.
    }

    /**
     * @notice Owner review of payout-operator-proposed scheduled payments in one call: approve some (bound
     *         to the exact content reviewed via expectedHashes[i]; a proposer edit after review reverts the
     *         whole call) and reject others by removing them (cancelIds). Approves run before cancels. The
     *         initialized check and immutable-lock deadline are computed once; approveIds/expectedHashes must
     *         be equal length. Access control (owner-only) is enforced by the facade, so all cancels are
     *         privileged owner removals.
     */
    function reviewScheduledPayments(
        VaultStorage storage vaultStorage,
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external onlyInitialized(vaultStorage) {
        if (approveIds.length != expectedHashes.length) revert ArrayLengthMismatch();
        uint256 immutableDeadline = _immutableLockDeadline(vaultStorage);
        for (uint256 i; i < approveIds.length; ++i) {
            _approveScheduledPayment(vaultStorage, approveIds[i], expectedHashes[i], immutableDeadline);
        }
        for (uint256 i; i < cancelIds.length; ++i) {
            _removeScheduledPayment(vaultStorage, cancelIds[i], true);
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
            // Approving an immutable proposal is when it becomes permanent-track, so its lock window
            // (re)starts here — the proposal's age must not shorten the owner's review period.
            vaultStorage.scheduledPaymentEffectiveAt[id] = immutableDeadline;
        }
        // The batched {ScheduledPaymentsApproved} event is emitted by the caller.
    }

    function _checkScheduledPayment(IBittyV1Vault.ScheduledPayment calldata scheduledPayment) internal view {
        if (scheduledPayment.scheduledPaymentAddress == address(0)) {
            revert AddressZero();
        }
        // assetAddress address(0) is the "pay in ETH" sentinel; any other asset must be a contract.
        if (scheduledPayment.assetAddress != address(0) && scheduledPayment.assetAddress.code.length == 0) {
            revert AssetAddressNotContract();
        }
        if (scheduledPayment.amount == 0) {
            revert AmountIsZero();
        }
        if (scheduledPayment.remainingPaymentCount == 0) {
            revert ScheduledPaymentPaymentCountZero();
        }
        if (scheduledPayment.remainingPaymentCount > 1 && scheduledPayment.paymentInterval < HIGH_RISK_TIMELOCK) {
            revert ScheduledPaymentIntervalTooShort();
        }
    }

    /**
     * @notice Remove one or more scheduled payments. The initialized check runs once for the batch.
     *         Access control (owner-or-pending-proposer) is enforced by the facade + the per-item check.
     */
    function removeScheduledPayments(VaultStorage storage vaultStorage, uint256[] calldata ids, bool byOwner)
        external
        onlyInitialized(vaultStorage)
    {
        for (uint256 i; i < ids.length; ++i) {
            _removeScheduledPayment(vaultStorage, ids[i], byOwner);
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.ScheduledPaymentsRemoved(ids);
    }

    function _removeScheduledPayment(VaultStorage storage vaultStorage, uint256 id, bool byOwner) private {
        if (!byOwner && vaultStorage.scheduledPaymentPendingProposer[id] != msg.sender) {
            revert NotProposalOwner();
        }
        // An approved immutable entry with payments remaining is permanent once its lock window has
        // passed — not even the owner can remove it, so it survives an owner-key compromise and the
        // vault's renounce. (Exhausted entries may be cleaned up; pending proposals were never approved.)
        if (_isLockedImmutable(vaultStorage, id)) {
            revert ImmutableScheduledPaymentLocked();
        }
        delete vaultStorage.scheduledPayments[id];
        delete vaultStorage.scheduledPaymentPendingProposer[id];
        delete vaultStorage.lastReceiveTimestamps[id];
        // Removal is allowed at any time, including during the protection window — that window exists so a
        // malicious entry can be caught and deleted before it can ever pay. The timer is per-id, so it goes
        // away with the entry (no shared-address exploit).
        delete vaultStorage.scheduledPaymentEffectiveAt[id];
        // The batched {ScheduledPaymentsRemoved} event is emitted by the caller.
    }

    /**
     * @notice Verify the owner's pre-committed rescue and mark the vault renounced.
     *         `rescueScheduledPaymentId` must be a LOCKED IMMUTABLE scheduled payment
     *         (immutable, approved, past its lock deadline, payments remaining) — the
     *         only entry an attacker with the same key can neither forge nor remove,
     *         and the only one that keeps paying (permissionlessly, via payScheduled)
     *         once the vault is ownerless. Reverts {NoRescueTarget} otherwise, so
     *         renouncing can never strand the funds.
     *
     *         O(1): it names one payment and clears nothing. After the flag is set,
     *         payScheduled refuses every non-locked-immutable payment, so an
     *         attacker's injected mutable payments go inert with no loop — meaning an
     *         attacker CANNOT grief the renounce by inflating the payment count.
     */
    function prepareRenounce(VaultStorage storage vaultStorage, uint256 rescueScheduledPaymentId)
        external
        onlyInitialized(vaultStorage)
    {
        if (!_isLockedImmutable(vaultStorage, rescueScheduledPaymentId)) {
            revert NoRescueTarget();
        }
        vaultStorage.renounced = true;
    }

    /**
     * @dev A scheduled payment that is permanent and still active: immutable, approved
     *      (not a pending proposal), past its lock deadline, and with payments left.
     *      The sole survivor of renounce and the only thing an ownerless vault pays.
     */
    function _isLockedImmutable(VaultStorage storage vaultStorage, uint256 id) internal view returns (bool) {
        IBittyV1Vault.ScheduledPayment storage p = vaultStorage.scheduledPayments[id];
        return p.isImmutable && p.remainingPaymentCount > 0
            && vaultStorage.scheduledPaymentPendingProposer[id] == address(0)
            && block.timestamp >= vaultStorage.scheduledPaymentEffectiveAt[id];
    }

    /**
     * @notice Owner: update any subset of the payment-risk controls in one call. A field left at the
     *         {UNCHANGED} sentinel (type(uint256).max) is skipped entirely — no SLOAD, no SSTORE — so only
     *         the fields actually changing cost storage gas. Every applied field still passes through the
     *         loosen-waits-changeTimelock guard (loosening is delayed, tightening is immediate), so this is
     *         not a blind struct copy. The effective changeTimelock is read once up front and used as the
     *         delay for every field including changeTimelock itself, so a same-call reduction of the delay
     *         cannot speed up the other loosenings.
     */
    function updatePaymentRisk(VaultStorage storage vaultStorage, IBittyV1Owner.PaymentRisk calldata u)
        external
        onlyInitialized(vaultStorage)
    {
        uint64 timelock = _effective(vaultStorage.riskConfig.changeTimelock);
        if (u.scheduledPaymentProtection != UNCHANGED) {
            if (u.scheduledPaymentProtection > MAX_SCHEDULED_PAYMENT_PROTECTION) {
                revert ScheduledPaymentProtectionTooLong();
            }
            _setHigherSafer(vaultStorage.riskConfig.scheduledPaymentProtection, u.scheduledPaymentProtection, timelock);
        }
        if (u.whitelistedProtection != UNCHANGED) {
            _setHigherSafer(vaultStorage.riskConfig.whitelistedProtection, u.whitelistedProtection, timelock);
        }
        if (u.maxSendValue != UNCHANGED) {
            _setCap(vaultStorage.riskConfig.maxSendValue, u.maxSendValue, timelock);
        }
        // maxSendInterval: the rolling window over which maxSendValue caps cumulative one-off sends. Longer =
        // safer, so shortening/clearing it is a loosening; 0 = per-transaction cap only.
        if (u.maxSendInterval != UNCHANGED) {
            _setHigherSafer(vaultStorage.riskConfig.maxSendInterval, u.maxSendInterval, timelock);
        }
        if (u.maxScheduledValue != UNCHANGED) {
            _setCap(vaultStorage.riskConfig.maxScheduledValue, u.maxScheduledValue, timelock);
        }
        if (u.maxWhitelistedValue != UNCHANGED) {
            _setCap(vaultStorage.riskConfig.maxWhitelistedValue, u.maxWhitelistedValue, timelock);
        }
        // changeTimelock: lowering it is a loosening (waits the current delay); raising is immediate. Keeps a
        // compromised key from zeroing the delay and then loosening everything instantly.
        if (u.changeTimelock != UNCHANGED) {
            _setHigherSafer(vaultStorage.riskConfig.changeTimelock, u.changeTimelock, timelock);
        }
        emit IBittyV1Owner.PaymentRiskUpdated(u);
    }

    function updatePayoutOperators(
        VaultStorage storage vaultStorage,
        address[] calldata addPayoutOperators,
        address[] calldata removePayoutOperators
    ) external onlyInitialized(vaultStorage) {
        for (uint256 i; i < addPayoutOperators.length; ++i) {
            if (addPayoutOperators[i] == address(0)) revert AddressZero();
            if (vaultStorage.payoutOperators.contains(addPayoutOperators[i])) {
                revert PayoutOperatorAlreadyRegistered();
            }
            vaultStorage.payoutOperators.add(addPayoutOperators[i]);
        }
        for (uint256 i; i < removePayoutOperators.length; ++i) {
            if (!vaultStorage.payoutOperators.remove(removePayoutOperators[i])) revert PayoutOperatorNotFound();
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
        returns (
            uint64 scheduledPaymentProtection,
            uint64 whitelistedProtection,
            uint64 maxSendValue,
            uint64 maxScheduledValue,
            uint64 maxWhitelistedValue,
            uint64 changeTimelock,
            uint64 maxSendInterval
        )
    {
        RiskConfig storage r = vaultStorage.riskConfig;
        return (
            _effective(r.scheduledPaymentProtection),
            _effective(r.whitelistedProtection),
            _effective(r.maxSendValue),
            _effective(r.maxScheduledValue),
            _effective(r.maxWhitelistedValue),
            _effective(r.changeTimelock),
            _effective(r.maxSendInterval)
        );
    }

    /**
     * @notice Deadline for a newly added/edited entry given its protection window; 0 when disabled.
     */
    function _protectionDeadline(uint256 protection) private view returns (uint256) {
        return protection == 0 ? 0 : block.timestamp + protection;
    }

    /**
     * @notice Deadline after which an approved immutable scheduled payment is permanently locked.
     * @dev Floor/cap the protection window so zero-protection vaults still get a review period before
     *      irreversibility, and a compromised owner cannot plant a multi-year delay.
     */
    function _immutableLockDeadline(VaultStorage storage vaultStorage) private view returns (uint256) {
        return _immutableLockDeadlineFromWindow(_effective(vaultStorage.riskConfig.scheduledPaymentProtection));
    }

    /**
     * @dev Same as {_immutableLockDeadline} but takes an already-read protection window, so a batch can read
     *      the timelocked value once and reuse it across every item.
     */
    function _immutableLockDeadlineFromWindow(uint64 window) private view returns (uint256) {
        uint256 w = window;
        if (w < STANDARD_RISK_TIMELOCK) w = STANDARD_RISK_TIMELOCK;
        if (w > HIGH_RISK_TIMELOCK) w = HIGH_RISK_TIMELOCK;
        return block.timestamp + w;
    }

    /**
     * @notice Revert while an entry's protection window is still open.
     */
    function _requireProtectionElapsed(uint256 effectiveAt) private view {
        if (block.timestamp < effectiveAt) {
            revert ProtectionPeriodNotEnded();
        }
    }

    /**
     * @notice Add one or more whitelisted recipients under fresh auto-increment ids. The initialized check
     *         and the protection-window deadline are read once for the whole batch; arrays must be equal
     *         length. Access control (owner-or-payout-operator) is enforced by the facade.
     */
    function addWhitelistedRecipients(
        VaultStorage storage vaultStorage,
        address[] calldata recipients,
        address[] calldata allowedAssets,
        bool byOwner
    ) external onlyInitialized(vaultStorage) returns (uint256[] memory ids) {
        if (recipients.length != allowedAssets.length) revert ArrayLengthMismatch();
        uint256 protectionDeadline = _protectionDeadline(_effective(vaultStorage.riskConfig.whitelistedProtection));
        ids = new uint256[](recipients.length);
        for (uint256 i; i < recipients.length; ++i) {
            ids[i] =
                _addWhitelistedRecipient(vaultStorage, recipients[i], allowedAssets[i], byOwner, protectionDeadline);
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.WhitelistedRecipientsSet(ids, recipients, allowedAssets);
    }

    function _addWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        address recipient,
        address allowedAsset,
        bool byOwner,
        uint256 protectionDeadline
    ) private returns (uint256 id) {
        if (recipient == address(0)) {
            revert AddressZero();
        }
        id = ++vaultStorage.nextWhitelistedRecipientId;
        vaultStorage.whitelistedRecipients[id] =
            IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset});
        if (!byOwner) {
            vaultStorage.whitelistedRecipientPendingProposer[id] = msg.sender;
        }
        vaultStorage.whitelistedRecipientEffectiveAt[id] = protectionDeadline;
        // The batched {WhitelistedRecipientsSet} event is emitted by the caller.
    }

    /**
     * @notice Update one or more existing whitelisted recipients. The initialized check and protection-window
     *         deadline are read once for the whole batch; arrays must be equal length. Reverts if any `id`
     *         does not exist. Access control (owner-or-payout-operator) is enforced by the facade.
     */
    function updateWhitelistedRecipients(
        VaultStorage storage vaultStorage,
        uint256[] calldata ids,
        address[] calldata recipients,
        address[] calldata allowedAssets,
        bool byOwner
    ) external onlyInitialized(vaultStorage) {
        if (ids.length != recipients.length || recipients.length != allowedAssets.length) {
            revert ArrayLengthMismatch();
        }
        uint256 protectionDeadline = _protectionDeadline(_effective(vaultStorage.riskConfig.whitelistedProtection));
        for (uint256 i; i < ids.length; ++i) {
            _updateWhitelistedRecipient(
                vaultStorage, ids[i], recipients[i], allowedAssets[i], byOwner, protectionDeadline
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
        uint256 protectionDeadline
    ) private {
        if (recipient == address(0)) {
            revert AddressZero();
        }
        if (vaultStorage.whitelistedRecipients[id].recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        if (byOwner) {
            delete vaultStorage.whitelistedRecipientPendingProposer[id];
        } else if (vaultStorage.whitelistedRecipientPendingProposer[id] != msg.sender) {
            revert NotProposalOwner();
        }
        vaultStorage.whitelistedRecipients[id] =
            IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset});
        vaultStorage.whitelistedRecipientEffectiveAt[id] = protectionDeadline;
        // The batched {WhitelistedRecipientsSet} event is emitted by the caller.
    }

    /**
     * @notice Owner review of payout-operator-proposed whitelisted recipients in one call: approve some
     *         (bound to the exact content reviewed via expectedHashes[i]) and reject others by removing them
     *         (cancelIds). Approves run before cancels. The initialized check runs once;
     *         approveIds/expectedHashes must be equal length. Access control (owner-only) is enforced by the
     *         facade, so all cancels are privileged owner removals.
     */
    function reviewWhitelistedRecipients(
        VaultStorage storage vaultStorage,
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external onlyInitialized(vaultStorage) {
        if (approveIds.length != expectedHashes.length) revert ArrayLengthMismatch();
        for (uint256 i; i < approveIds.length; ++i) {
            _approveWhitelistedRecipient(vaultStorage, approveIds[i], expectedHashes[i]);
        }
        for (uint256 i; i < cancelIds.length; ++i) {
            _removeWhitelistedRecipient(vaultStorage, cancelIds[i], true);
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
        // The batched {WhitelistedRecipientsApproved} event is emitted by the caller.
    }

    /**
     * @notice Remove one or more whitelisted recipients. The initialized check runs once for the batch.
     *         Reverts if any `id` does not exist. Access control (owner-or-pending-proposer) is enforced by
     *         the facade + the per-item check.
     */
    function removeWhitelistedRecipients(VaultStorage storage vaultStorage, uint256[] calldata ids, bool byOwner)
        external
        onlyInitialized(vaultStorage)
    {
        for (uint256 i; i < ids.length; ++i) {
            _removeWhitelistedRecipient(vaultStorage, ids[i], byOwner);
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.WhitelistedRecipientsRemoved(ids);
    }

    function _removeWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, bool byOwner) private {
        address recipient = vaultStorage.whitelistedRecipients[id].recipient;
        if (recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        if (!byOwner && vaultStorage.whitelistedRecipientPendingProposer[id] != msg.sender) {
            revert NotProposalOwner();
        }
        delete vaultStorage.whitelistedRecipients[id];
        delete vaultStorage.whitelistedRecipientPendingProposer[id];
        // Removable at any time, including mid-protection-window — that is how a malicious recipient gets
        // caught and dropped before it can pay. The per-id timer is cleared with the entry.
        delete vaultStorage.whitelistedRecipientEffectiveAt[id];
        // The batched {WhitelistedRecipientsRemoved} event is emitted by the caller.
    }

    /**
     * @notice Pay a whitelisted recipient a discretionary amount from the vault's balance.
     * @dev Access control (owner-only) is enforced by the facade. Not rate-limited — recipients are vetted
     *      at set time — but a newly added recipient is time-locked by whitelistedProtection until its
     *      window elapses.
     */
    /**
     * @notice Pay one or more whitelisted recipients a discretionary amount from the vault's balance
     *         (row `i` = ids[i]/assets[i]/amounts[i]). The initialized check and the risk cap are read once
     *         for the whole batch; arrays must be equal length. Access control (owner-only) and any yield-
     *         position sourcing are handled by the facade before this runs.
     * @dev Not rate-limited — recipients are vetted at set time — but a newly added recipient is time-locked
     *      by whitelistedProtection until its window elapses.
     */
    function sendToWhitelistedRecipients(
        VaultStorage storage vaultStorage,
        uint256[] calldata ids,
        address[] calldata assets,
        uint256[] calldata amounts
    ) external onlyInitialized(vaultStorage) {
        if (ids.length != assets.length || assets.length != amounts.length) {
            revert ArrayLengthMismatch();
        }
        uint64 cap = _effective(vaultStorage.riskConfig.maxWhitelistedValue);
        address[] memory recipients = new address[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            recipients[i] = _sendToWhitelistedRecipient(vaultStorage, ids[i], assets[i], amounts[i], cap);
        }
        // One event per batch; amounts equal the amounts paid (full amount per row).
        if (ids.length > 0) emit IBittyV1Owner.WhitelistedRecipientsPaid(ids, recipients, assets, amounts);
    }

    function _sendToWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        uint256 id,
        address asset,
        uint256 amount,
        uint64 cap
    ) private returns (address recipient) {
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
        _checkPaymentRiskCap(vaultStorage, cap, asset, amount);
        _requireProtectionElapsed(vaultStorage.whitelistedRecipientEffectiveAt[id]);
        _payOut(vaultStorage, asset, amount, entry.recipient);
        recipient = entry.recipient;
        // The batched {WhitelistedRecipientsPaid} event is emitted by the caller.
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

    /**
     * @notice Pay each scheduled payment `ids[i]` its full scheduled amount. The initialized check runs
     *         once for the whole batch; each entry is still individually trigger-gated.
     */
    function payScheduled(VaultStorage storage vaultStorage, uint256[] calldata ids)
        external
        onlyInitialized(vaultStorage)
    {
        uint256 n = ids.length;
        uint256[] memory paidIds = new uint256[](n);
        address[] memory addrs = new address[](n);
        address[] memory assetsOut = new address[](n);
        uint256[] memory amountsOut = new uint256[](n);
        uint8[] memory counts = new uint8[](n);
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            (bool skipped, address addr, address asset, uint256 amount, uint8 count) =
                _payScheduledById(vaultStorage, ids[i]);
            // A pay-with-insufficient-balance entry with zero balance is skipped (no transfer, no slot
            // consumed) — exclude it from the batch event.
            if (skipped) continue;
            paidIds[paid] = ids[i];
            addrs[paid] = addr;
            assetsOut[paid] = asset;
            amountsOut[paid] = amount;
            counts[paid] = count;
            ++paid;
        }
        // Trim the over-allocated arrays down to the number actually paid.
        assembly {
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

    function _payScheduledById(VaultStorage storage vaultStorage, uint256 id)
        private
        returns (
            bool skipped,
            address scheduledPaymentAddress,
            address assetAddress,
            uint256 paidAmount,
            uint8 remainingPaymentCount
        )
    {
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[id];
        if (scheduledPayment.trigger != address(0) && msg.sender != scheduledPayment.trigger) {
            revert ScheduledPaymentTriggerError();
        }
        return _payScheduled(vaultStorage, scheduledPayment, id, scheduledPayment.amount);
    }

    function payScheduledAmount(VaultStorage storage vaultStorage, uint256 id, uint256 amount)
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
        if (msg.sender != scheduledPayment.trigger) {
            revert ScheduledPaymentTriggerError();
        }
        (bool skipped, address addr, address asset, uint256 paid, uint8 count) =
            _payScheduled(vaultStorage, scheduledPayment, id, amount);
        if (!skipped) _emitOnePaid(id, addr, asset, paid, count);
    }

    /**
     * @dev Emit the batched {ScheduledPaymentsPaid} for a single payment (a one-element array), so the
     *      single-payment paths share the batch event shape.
     */
    function _emitOnePaid(uint256 id, address addr, address asset, uint256 amount, uint8 count) private {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        address[] memory addrs = new address[](1);
        addrs[0] = addr;
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint8[] memory counts = new uint8[](1);
        counts[0] = count;
        emit IBittyV1Vault.ScheduledPaymentsPaid(ids, addrs, assets, amounts, counts);
    }

    /**
     * @notice Run every {payScheduled} eligibility check and apply its state effects without transferring —
     *         returning the payee, asset and amount so the caller can deliver funds from a yield position.
     *         The recipient is hard-sourced from the scheduled payment config.
     */
    function accrueScheduledPaymentOnBehalf(VaultStorage storage vaultStorage, uint256 id)
        external
        onlyInitialized(vaultStorage)
        returns (address scheduledPaymentAddress, address assetAddress, uint256 payAmount)
    {
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[id];
        if (scheduledPayment.trigger != address(0) && msg.sender != scheduledPayment.trigger) {
            revert ScheduledPaymentTriggerError();
        }
        payAmount = scheduledPayment.amount;
        // fromPosition = true: the payout is delivered from the yield position, not the vault balance,
        // so the zero-vault-balance skip must not apply (it would wrongly leave the payment unconsumed).
        _accrueScheduledPayment(vaultStorage, scheduledPayment, id, true);
        scheduledPaymentAddress = scheduledPayment.scheduledPaymentAddress;
        assetAddress = scheduledPayment.assetAddress;
        _emitOnePaid(id, scheduledPaymentAddress, assetAddress, payAmount, scheduledPayment.remainingPaymentCount);
    }

    /**
     * @dev Returns skipped=true (with zeroed payload) when a pay-with-insufficient-balance entry has zero
     *      vault balance; otherwise the payment details. The {ScheduledPaymentsPaid} event is emitted by the
     *      caller so batch and single paths can share one event shape.
     */
    function _payScheduled(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment storage scheduledPayment,
        uint256 id,
        uint256 payAmount
    )
        internal
        returns (
            bool skipped,
            address scheduledPaymentAddress,
            address assetAddress,
            uint256 paidAmount,
            uint8 remainingPaymentCount
        )
    {
        if (_accrueScheduledPayment(vaultStorage, scheduledPayment, id, false)) {
            return (true, address(0), address(0), 0, 0);
        }
        paidAmount = _transferMoney(
            vaultStorage,
            scheduledPayment.assetAddress,
            payAmount,
            scheduledPayment.scheduledPaymentAddress,
            scheduledPayment.payWithInsufficientBalance
        );
        scheduledPaymentAddress = scheduledPayment.scheduledPaymentAddress;
        assetAddress = scheduledPayment.assetAddress;
        remainingPaymentCount = scheduledPayment.remainingPaymentCount;
    }

    /**
     * @dev Shared accrual for pay-from-vault and pay-from-yield paths. Returns true when a
     *      pay-with-insufficient-balance entry has zero vault balance — skip transfer without consuming a slot.
     */
    function _accrueScheduledPayment(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment storage scheduledPayment,
        uint256 id,
        bool fromPosition
    ) internal returns (bool skipped) {
        if (scheduledPayment.amount == 0) {
            revert ScheduledPaymentNotFound();
        }
        // Ownerless vault: only the pre-committed locked immutable payments pay
        // out; everything else (including anything an attacker injected before
        // renounce) is inert. No clearing loop was needed at renounce.
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

        // A payment that tolerates insufficient balance and has nothing to pay (zero balance) would
        // deliver 0. Skip it without burning a payment count or moving the interval clock — otherwise a
        // payee silently loses a whole period for a zero delivery. Not applicable when paying straight
        // from a yield position (`fromPosition`): the funds come from the position, not the vault balance.
        if (!fromPosition && scheduledPayment.payWithInsufficientBalance) {
            address balanceToken =
                scheduledPayment.assetAddress == address(0) ? vaultStorage.weth : scheduledPayment.assetAddress;
            if (IERC20(balanceToken).balanceOf(address(this)) == 0) {
                return true;
            }
        }

        vaultStorage.lastReceiveTimestamps[id] = block.timestamp;
        // type(uint8).max is the "unlimited" sentinel: an uncapped recurring scheduled payment that never
        // decrements and so never runs out.
        if (scheduledPayment.remainingPaymentCount != type(uint8).max) {
            scheduledPayment.remainingPaymentCount = scheduledPayment.remainingPaymentCount - 1;
        }
    }

    function _transferMoney(
        VaultStorage storage vaultStorage,
        address erc20Address,
        uint256 amount,
        address scheduledPaymentAddress,
        bool payWithInsufficientBalance
    ) internal returns (uint256 paidAmount) {
        address balanceToken = erc20Address == address(0) ? vaultStorage.weth : erc20Address;
        uint256 balance = IERC20(balanceToken).balanceOf(address(this));
        if (!payWithInsufficientBalance && balance < amount) {
            revert InsufficientBalance();
        }
        paidAmount = balance < amount ? balance : amount;
        _payOut(vaultStorage, erc20Address, paidAmount, scheduledPaymentAddress);
    }

    /**
     * @dev `asset == address(0)` pays native ETH by unwrapping WETH — the only payout that .call's an
     *      arbitrary recipient, hence the reentrancy guard.
     */
    function _payOut(VaultStorage storage vaultStorage, address asset, uint256 amount, address to) internal {
        if (amount == 0) {
            return;
        }
        if (asset == address(0)) {
            if (vaultStorage.payingEth) {
                revert ReentrantCall();
            }
            vaultStorage.payingEth = true;
            WETH(payable(vaultStorage.weth)).withdraw(amount);
            (bool ok,) = to.call{value: amount}("");
            if (!ok) {
                revert TransferFailed();
            }
            vaultStorage.payingEth = false;
        } else {
            IERC20(asset).safeTransfer(to, amount);
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
        if (vaultStorage.guard.isAssetRegistered(assetAddress)) {
            vaultStorage.assets.add(assetAddress);
        } else if (vaultStorage.guard.isStableCoinRegistered(assetAddress)) {
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

    function checkAsset(VaultStorage storage logicStorage, address assetAddress) external view {
        if (logicStorage.assets.contains(assetAddress) || logicStorage.stableCoins.contains(assetAddress)) {
            return;
        }
        revert NotRegistered();
    }
}
