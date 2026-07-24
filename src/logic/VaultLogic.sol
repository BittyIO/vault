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
    EmptyArray
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {IBittyV1Operator} from "../interfaces/IBittyV1Operator.sol";
import {IBittyV1Guard, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {VaultStorage, PendingSend, RiskConfig, TimelockedValue, OperatorLimit} from "./Storages.sol";
import {
    IBittyV1Vault,
    ScheduledPaymentNotFound,
    ScheduledPaymentImmutable,
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
    PendingSendNotFound,
    PaymentExceedsRiskCap,
    PaymentExceedsPeriodLimit,
    PaymentNotStableCoin,
    OperatorSendCapZero,
    OperatorIntervalZero,
    OperatorNotFound,
    OperatorAlreadyRegistered,
    RiskControlLevel
} from "../interfaces/IBittyV1Vault.sol";

library VaultLogic {
    /**
     * The vault will be drained by one attack in a very short time if no this protection.
     * @dev this is a protection for the vault.
     */
    uint256 constant SCHEDULED_PAYMENT_MINIMAL_INTERVAL = 7 days;

    // Upper bound (~10 years) on the scheduled-payment protection window. A sanity cap so the owner can
    // never set an absurd/effectively-infinite delay that permanently blocks the recurring-payment path.
    // (Solidity has no `years` unit — leap years make it ambiguous — so this is expressed in days.)
    uint64 constant MAX_SCHEDULED_PAYMENT_PROTECTION = 3650 days;

    // ---- Risk-control-level default parameters (payment controls) ----
    // TODO(risk-params): fill in the Standard/High defaults. `Zero` is all-zero (no controls).
    // Protection windows are seconds; the *_MAX_*_VALUE caps are stablecoin whole tokens
    // (0 = unrestricted / no stablecoin lock); *_CHANGE_TIMELOCK is the loosening delay in seconds.
    uint64 constant STANDARD_SCHEDULED_PAYMENT_PROTECTION = 1 days;
    uint64 constant STANDARD_WHITELISTED_PROTECTION = 1 days;
    uint64 constant STANDARD_MAX_SEND_VALUE = 100;
    uint64 constant STANDARD_MAX_SCHEDULED_VALUE = 100;
    uint64 constant STANDARD_MAX_WHITELISTED_VALUE = 100;
    uint64 constant STANDARD_CHANGE_TIMELOCK = 1 days;

    uint64 constant HIGH_SCHEDULED_PAYMENT_PROTECTION = 3 days;
    uint64 constant HIGH_WHITELISTED_PROTECTION = 3 days;
    uint64 constant HIGH_MAX_SEND_VALUE = 1000;
    uint64 constant HIGH_MAX_SCHEDULED_VALUE = 1000;
    uint64 constant HIGH_MAX_WHITELISTED_VALUE = 1000;
    uint64 constant HIGH_CHANGE_TIMELOCK = 3 days;

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
     * changeTimelock so any later change is instant); Standard and High seed the guardrails plus a
     * loosening delay. Every value the owner may later change freely, but loosening waits changeTimelock.
     */
    function _defaultRisk(RiskControlLevel level) internal pure returns (RiskConfig memory c) {
        if (level == RiskControlLevel.Standard) {
            c.scheduledPaymentProtection.value = STANDARD_SCHEDULED_PAYMENT_PROTECTION;
            c.whitelistedProtection.value = STANDARD_WHITELISTED_PROTECTION;
            c.maxSendValue.value = STANDARD_MAX_SEND_VALUE;
            c.maxScheduledValue.value = STANDARD_MAX_SCHEDULED_VALUE;
            c.maxWhitelistedValue.value = STANDARD_MAX_WHITELISTED_VALUE;
            c.changeTimelock.value = STANDARD_CHANGE_TIMELOCK;
        } else if (level == RiskControlLevel.High) {
            c.scheduledPaymentProtection.value = HIGH_SCHEDULED_PAYMENT_PROTECTION;
            c.whitelistedProtection.value = HIGH_WHITELISTED_PROTECTION;
            c.maxSendValue.value = HIGH_MAX_SEND_VALUE;
            c.maxScheduledValue.value = HIGH_MAX_SCHEDULED_VALUE;
            c.maxWhitelistedValue.value = HIGH_MAX_WHITELISTED_VALUE;
            c.changeTimelock.value = HIGH_CHANGE_TIMELOCK;
        }
    }

    /**
     * @notice Enforce a per-path payment risk cap. When `cap` is non-zero the payment must be a
     * stablecoin whose amount is within `cap` whole tokens; `cap == 0` disables the check.
     */
    function _checkPaymentRiskCap(VaultStorage storage vaultStorage, uint64 cap, address asset, uint256 amount)
        private
        view
    {
        if (cap == 0) return;
        if (!vaultStorage.stableCoins.contains(asset)) revert PaymentNotStableCoin();
        if (amount > uint256(cap) * (10 ** IERC20Metadata(asset).decimals())) revert PaymentExceedsRiskCap();
    }

    // The currently in-force value of a timelocked control (a queued loosening applies once its delay elapses).
    function _effective(TimelockedValue storage tv) private view returns (uint64) {
        if (tv.pendingAt != 0 && block.timestamp >= tv.pendingAt) return tv.pending;
        return tv.value;
    }

    // Promote an elapsed pending change into the live value so the next comparison uses the current baseline.
    function _settle(TimelockedValue storage tv) private {
        if (tv.pendingAt != 0 && block.timestamp >= tv.pendingAt) {
            tv.value = tv.pending;
            tv.pending = 0;
            tv.pendingAt = 0;
        }
    }

    // Store `next`: a tightening (or equal) change is immediate; a loosening one only applies after
    // `timelock` seconds. `loosen` is decided by the caller against the settled current value.
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

    // For scheduled/whitelisted protection & changeTimelock: higher = safer, so lowering is a loosening.
    function _setHigherSafer(TimelockedValue storage tv, uint256 next, uint64 timelock) private {
        _settle(tv);
        uint64 n = uint64(next);
        _apply(tv, n, n < tv.value, timelock);
    }

    // For caps: 0 = unrestricted (least safe), else lower = safer. Raising, or clearing to 0, is a loosening.
    function _setCap(TimelockedValue storage tv, uint256 next, uint64 timelock) private {
        _settle(tv);
        uint64 n = uint64(next);
        bool loosen = tv.value != 0 && (n == 0 || n > tv.value);
        _apply(tv, n, loosen, timelock);
    }

    /**
     * @dev Validates a batch (array lengths, non-zero recipients/amounts, stablecoin-only when a cap
     * or operator period quota is active, and the aggregate risk cap) in a single pass. When `execute` is
     * true each transfer is performed only after all checks pass. `operatorAddr` must be the vault's
     * operator for period-quota enforcement; the owner direct-send path passes address(0). When
     * `updatePeriodAccounting` is true the operator's period tally is incremented (approval execution only).
     */
    function _processSendBatch(
        VaultStorage storage vaultStorage,
        address[] memory recipients,
        address[] memory assets,
        uint256[] memory amounts,
        bool execute,
        address operatorAddr,
        bool updatePeriodAccounting
    ) private {
        uint256 length = recipients.length;
        if (length == 0) revert EmptyArray();
        if (assets.length != length || amounts.length != length) revert ArrayLengthMismatch();

        uint64 cap = _effective(vaultStorage.riskConfig.maxSendValue);
        OperatorLimit storage opLimit = vaultStorage.operatorLimits[operatorAddr];
        bool periodLimitActive = operatorAddr != address(0) && vaultStorage.operators.contains(operatorAddr)
            && opLimit.interval != 0 && opLimit.maxStableCoinPerPeriod != 0;
        bool requireStable = cap != 0 || periodLimitActive;

        uint256 totalStableValue;
        for (uint256 i = 0; i < length; i++) {
            address recipient = recipients[i];
            address asset = assets[i];
            uint256 amount = amounts[i];
            if (recipient == address(0)) revert AddressZero();
            if (amount == 0) revert AmountIsZero();
            if (requireStable) {
                if (!vaultStorage.stableCoins.contains(asset)) revert PaymentNotStableCoin();
                uint256 scale = 10 ** IERC20Metadata(asset).decimals();
                totalStableValue += Math.mulDiv(amount, 1e18, scale, Math.Rounding.Ceil);
                if (cap != 0 && totalStableValue > uint256(cap) * 1e18) revert PaymentExceedsRiskCap();
            }
        }

        if (periodLimitActive) {
            _checkOperatorSendPeriod(opLimit, totalStableValue, updatePeriodAccounting);
        }

        if (!execute) return;

        for (uint256 i = 0; i < length; i++) {
            _payOut(vaultStorage, assets[i], amounts[i], recipients[i]);
        }
    }

    /**
     * @notice Enforce the operator's rolling one-off send quota. Resets the window when elapsed.
     */
    function _checkOperatorSendPeriod(OperatorLimit storage limit, uint256 batchStableValue, bool updateAccounting)
        private
    {
        uint128 periodStart = limit.periodStartTimestamp;
        uint256 sent = limit.sentInPeriod;

        if (periodStart == 0 || block.timestamp >= periodStart + limit.interval) {
            periodStart = uint128(block.timestamp);
            sent = 0;
        }

        if (sent + batchStableValue > uint256(limit.maxStableCoinPerPeriod) * 1e18) {
            revert PaymentExceedsPeriodLimit();
        }

        if (updateAccounting) {
            limit.periodStartTimestamp = periodStart;
            limit.sentInPeriod = sent + batchStableValue;
        }
    }

    function send(
        VaultStorage storage vaultStorage,
        address[] memory recipients,
        address[] memory assets,
        uint256[] memory amounts
    ) external onlyInitialized(vaultStorage) {
        _processSendBatch(vaultStorage, recipients, assets, amounts, true, address(0), false);
    }

    /**
     * @notice Queue a payment-manager-proposed one-off send for owner approval. Access control
     * (payment-manager) is enforced by the facade.
     */
    function proposeSend(
        VaultStorage storage vaultStorage,
        address[] memory recipients,
        address[] memory assets,
        uint256[] memory amounts
    ) external onlyInitialized(vaultStorage) returns (uint256 id) {
        _processSendBatch(vaultStorage, recipients, assets, amounts, false, msg.sender, false);
        id = vaultStorage.nextPendingSendId++;
        PendingSend storage ps = vaultStorage.pendingSends[id];
        ps.proposer = msg.sender;
        ps.recipients = recipients;
        ps.assets = assets;
        ps.amounts = amounts;
        emit IBittyV1Operator.SendProposed(id, msg.sender, recipients, assets, amounts);
    }

    /**
     * @notice Owner: execute a queued one-off send. Access control (owner-only) is enforced by the
     * facade.
     */
    function approveSend(VaultStorage storage vaultStorage, uint256 id) external onlyInitialized(vaultStorage) {
        PendingSend memory ps = vaultStorage.pendingSends[id];
        if (ps.proposer == address(0)) {
            revert PendingSendNotFound();
        }
        delete vaultStorage.pendingSends[id];
        // Re-check against the controls in force at approval time, so a tightening also binds an
        // already-queued batch.
        _processSendBatch(vaultStorage, ps.recipients, ps.assets, ps.amounts, true, ps.proposer, true);
        emit IBittyV1Owner.SendApproved(id, ps.recipients, ps.assets, ps.amounts);
    }

    /**
     * @notice Cancel a queued one-off send. The owner may cancel any; a payment manager may cancel
     * only its own. Access control (owner-or-proposer) is enforced by the facade + the check below.
     */
    function cancelSend(VaultStorage storage vaultStorage, uint256 id, bool byOwner)
        external
        onlyInitialized(vaultStorage)
    {
        PendingSend memory ps = vaultStorage.pendingSends[id];
        if (ps.proposer == address(0)) {
            revert PendingSendNotFound();
        }
        if (!byOwner && ps.proposer != msg.sender) {
            revert NotProposalOwner();
        }
        delete vaultStorage.pendingSends[id];
        emit IBittyV1Operator.SendCancelled(id);
    }

    function addScheduledPayment(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment memory scheduledPayment,
        bool byOwner
    ) external onlyInitialized(vaultStorage) returns (uint256 id) {
        if (scheduledPayment.startTimestamp < block.timestamp) {
            revert ScheduledPaymentStartTimestampInPast();
        }
        _checkScheduledPayment(scheduledPayment);
        _checkPaymentRiskCap(
            vaultStorage,
            _effective(vaultStorage.riskConfig.maxScheduledValue),
            scheduledPayment.assetAddress,
            scheduledPayment.amount
        );
        id = ++vaultStorage.nextScheduledPaymentId;
        vaultStorage.scheduledPayments[id] = scheduledPayment;
        // msg.sender (the proposing payment manager) survives the delegatecall from the facade.
        if (!byOwner) {
            vaultStorage.scheduledPaymentPendingProposer[id] = msg.sender;
        }
        vaultStorage.scheduledPaymentEffectiveAt[id] =
            _protectionDeadline(_effective(vaultStorage.riskConfig.scheduledPaymentProtection));
        emit IBittyV1Operator.ScheduledPaymentAdded(id, scheduledPayment);
    }

    function updateScheduledPayment(
        VaultStorage storage vaultStorage,
        uint256 id,
        IBittyV1Vault.ScheduledPayment memory scheduledPayment,
        bool byOwner
    ) external onlyInitialized(vaultStorage) {
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
            // A payment manager may only edit its own still-pending proposal, never an approved entry.
            revert NotProposalOwner();
        }
        _checkScheduledPayment(scheduledPayment);
        _checkPaymentRiskCap(
            vaultStorage,
            _effective(vaultStorage.riskConfig.maxScheduledValue),
            scheduledPayment.assetAddress,
            scheduledPayment.amount
        );
        vaultStorage.scheduledPayments[id] = scheduledPayment;
        vaultStorage.scheduledPaymentEffectiveAt[id] =
            _protectionDeadline(_effective(vaultStorage.riskConfig.scheduledPaymentProtection));
        emit IBittyV1Operator.ScheduledPaymentUpdated(id, scheduledPayment);
    }

    /**
     * @notice Owner approval of a payment-manager-proposed scheduled payment. Access control
     * (owner-only) is enforced by the facade. The owner binds the approval to the exact content they
     * reviewed via `expectedHash`; if the proposer edited the entry after review, the stored hash no
     * longer matches and the call reverts, so an approval can never confirm swapped content.
     */
    function approveScheduledPayment(VaultStorage storage vaultStorage, uint256 id, bytes32 expectedHash)
        external
        onlyInitialized(vaultStorage)
    {
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
        emit IBittyV1Owner.ScheduledPaymentApproved(id);
    }

    function _checkScheduledPayment(IBittyV1Vault.ScheduledPayment memory scheduledPayment) internal view {
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
        if (
            scheduledPayment.remainingPaymentCount > 1
                && scheduledPayment.paymentInterval < SCHEDULED_PAYMENT_MINIMAL_INTERVAL
        ) {
            revert ScheduledPaymentIntervalTooShort();
        }
    }

    function removeScheduledPayment(VaultStorage storage vaultStorage, uint256 id, bool byOwner)
        external
        onlyInitialized(vaultStorage)
    {
        // A payment manager may only cancel its own still-pending proposal; the owner can remove any.
        if (!byOwner && vaultStorage.scheduledPaymentPendingProposer[id] != msg.sender) {
            revert NotProposalOwner();
        }
        delete vaultStorage.scheduledPayments[id];
        delete vaultStorage.scheduledPaymentPendingProposer[id];
        delete vaultStorage.lastReceiveTimestamps[id];
        // Removal is allowed at any time, including during the protection window — that window exists so a
        // malicious entry can be caught and deleted before it can ever pay. The timer is per-id, so it goes
        // away with the entry (no shared-address exploit).
        delete vaultStorage.scheduledPaymentEffectiveAt[id];
        emit IBittyV1Operator.ScheduledPaymentRemoved(id);
    }

    function setScheduledPaymentProtection(VaultStorage storage vaultStorage, uint256 protection)
        external
        onlyInitialized(vaultStorage)
    {
        if (protection > MAX_SCHEDULED_PAYMENT_PROTECTION) {
            revert ScheduledPaymentProtectionTooLong();
        }
        _setHigherSafer(
            vaultStorage.riskConfig.scheduledPaymentProtection,
            protection,
            _effective(vaultStorage.riskConfig.changeTimelock)
        );
        emit IBittyV1Owner.ScheduledPaymentProtectionSet(protection);
    }

    function setWhitelistedProtection(VaultStorage storage vaultStorage, uint256 protection)
        external
        onlyInitialized(vaultStorage)
    {
        _setHigherSafer(
            vaultStorage.riskConfig.whitelistedProtection,
            protection,
            _effective(vaultStorage.riskConfig.changeTimelock)
        );
        emit IBittyV1Owner.WhitelistedProtectionSet(protection);
    }

    function setMaxSendValue(VaultStorage storage vaultStorage, uint256 value) external onlyInitialized(vaultStorage) {
        _setCap(vaultStorage.riskConfig.maxSendValue, value, _effective(vaultStorage.riskConfig.changeTimelock));
        emit IBittyV1Owner.MaxSendValueSet(value);
    }

    function setMaxScheduledValue(VaultStorage storage vaultStorage, uint256 value)
        external
        onlyInitialized(vaultStorage)
    {
        _setCap(vaultStorage.riskConfig.maxScheduledValue, value, _effective(vaultStorage.riskConfig.changeTimelock));
        emit IBittyV1Owner.MaxScheduledValueSet(value);
    }

    function setMaxWhitelistedValue(VaultStorage storage vaultStorage, uint256 value)
        external
        onlyInitialized(vaultStorage)
    {
        _setCap(vaultStorage.riskConfig.maxWhitelistedValue, value, _effective(vaultStorage.riskConfig.changeTimelock));
        emit IBittyV1Owner.MaxWhitelistedValueSet(value);
    }

    function setOperator(
        VaultStorage storage vaultStorage,
        address operator,
        uint256 interval,
        uint256 maxStableCoinPerPeriod
    ) external onlyInitialized(vaultStorage) {
        if (operator == address(0)) revert AddressZero();
        if (interval == 0) revert OperatorIntervalZero();
        if (maxStableCoinPerPeriod == 0) revert OperatorSendCapZero();
        if (vaultStorage.operators.contains(operator)) revert OperatorAlreadyRegistered();
        vaultStorage.operators.add(operator);
        OperatorLimit storage limit = vaultStorage.operatorLimits[operator];
        limit.interval = uint64(interval);
        limit.maxStableCoinPerPeriod = uint64(maxStableCoinPerPeriod);
        limit.periodStartTimestamp = 0;
        limit.sentInPeriod = 0;
        emit IBittyV1Owner.OperatorSendLimitSet(operator, interval, maxStableCoinPerPeriod);
    }

    function updateOperator(
        VaultStorage storage vaultStorage,
        address operator,
        uint256 interval,
        uint256 maxStableCoinPerPeriod
    ) external onlyInitialized(vaultStorage) {
        if (operator == address(0)) revert AddressZero();
        if (interval == 0) revert OperatorIntervalZero();
        if (maxStableCoinPerPeriod == 0) revert OperatorSendCapZero();
        if (!vaultStorage.operators.contains(operator)) revert OperatorNotFound();
        OperatorLimit storage limit = vaultStorage.operatorLimits[operator];
        limit.interval = uint64(interval);
        limit.maxStableCoinPerPeriod = uint64(maxStableCoinPerPeriod);
        emit IBittyV1Owner.OperatorSendLimitSet(operator, interval, maxStableCoinPerPeriod);
    }

    function removeOperator(VaultStorage storage vaultStorage, address operator)
        external
        onlyInitialized(vaultStorage)
    {
        if (!vaultStorage.operators.remove(operator)) revert OperatorNotFound();
        delete vaultStorage.operatorLimits[operator];
        emit IBittyV1Owner.OperatorRemoved(operator);
    }

    function getOperators(VaultStorage storage vaultStorage) external view returns (address[] memory) {
        return vaultStorage.operators.values();
    }

    function isOperator(VaultStorage storage vaultStorage, address account) external view returns (bool) {
        return vaultStorage.operators.contains(account);
    }

    /**
     * @notice Change the loosening delay itself. Lowering it is a loosening, so it waits the CURRENT
     * timelock; raising it takes effect immediately. Prevents a compromised key from zeroing the delay
     * and then loosening everything instantly.
     */
    function setChangeTimelock(VaultStorage storage vaultStorage, uint256 value)
        external
        onlyInitialized(vaultStorage)
    {
        _setHigherSafer(
            vaultStorage.riskConfig.changeTimelock, value, _effective(vaultStorage.riskConfig.changeTimelock)
        );
        emit IBittyV1Owner.ChangeTimelockSet(value);
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
            uint64 changeTimelock
        )
    {
        RiskConfig storage r = vaultStorage.riskConfig;
        return (
            _effective(r.scheduledPaymentProtection),
            _effective(r.whitelistedProtection),
            _effective(r.maxSendValue),
            _effective(r.maxScheduledValue),
            _effective(r.maxWhitelistedValue),
            _effective(r.changeTimelock)
        );
    }

    /**
     * @notice Deadline (unix time) for a newly added/edited entry given its protection window; 0 when the
     * window is disabled (payable immediately). The entry is not payable until block.timestamp reaches it.
     */
    function _protectionDeadline(uint256 protection) private view returns (uint256) {
        return protection == 0 ? 0 : block.timestamp + protection;
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
     * @notice Add a whitelisted recipient under a fresh auto-increment id.
     * @dev Access control (owner-only) is enforced by the facade.
     */
    function addWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        address recipient,
        address allowedAsset,
        bool byOwner
    ) external onlyInitialized(vaultStorage) returns (uint256 id) {
        if (recipient == address(0)) {
            revert AddressZero();
        }
        id = ++vaultStorage.nextWhitelistedRecipientId;
        vaultStorage.whitelistedRecipients[id] =
            IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset});
        if (!byOwner) {
            vaultStorage.whitelistedRecipientPendingProposer[id] = msg.sender;
        }
        vaultStorage.whitelistedRecipientEffectiveAt[id] =
            _protectionDeadline(_effective(vaultStorage.riskConfig.whitelistedProtection));
        emit IBittyV1Operator.WhitelistedRecipientSet(id, recipient, allowedAsset);
    }

    /**
     * @notice Update an existing whitelisted recipient. Reverts if `id` does not exist.
     * @dev Access control (owner-or-payment-manager) is enforced by the facade.
     */
    function updateWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        uint256 id,
        address recipient,
        address allowedAsset,
        bool byOwner
    ) external onlyInitialized(vaultStorage) {
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
        vaultStorage.whitelistedRecipientEffectiveAt[id] =
            _protectionDeadline(_effective(vaultStorage.riskConfig.whitelistedProtection));
        emit IBittyV1Operator.WhitelistedRecipientSet(id, recipient, allowedAsset);
    }

    /**
     * @notice Owner approval of a payment-manager-proposed whitelisted recipient. Access control
     * (owner-only) is enforced by the facade.
     */
    function approveWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id)
        external
        onlyInitialized(vaultStorage)
    {
        if (vaultStorage.whitelistedRecipients[id].recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        if (vaultStorage.whitelistedRecipientPendingProposer[id] == address(0)) {
            revert NotPendingApproval();
        }
        delete vaultStorage.whitelistedRecipientPendingProposer[id];
        emit IBittyV1Owner.WhitelistedRecipientApproved(id);
    }

    /**
     * @notice Remove a whitelisted recipient. Reverts if `id` does not exist.
     * @dev Access control (owner-or-pending-proposer) is enforced by the facade + the check below.
     */
    function removeWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, bool byOwner)
        external
        onlyInitialized(vaultStorage)
    {
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
        emit IBittyV1Operator.WhitelistedRecipientRemoved(id);
    }

    /**
     * @notice Pay a whitelisted recipient a discretionary amount from the vault's balance.
     * @dev Access control (owner-only) is enforced by the facade. The asset must match the entry's
     * allowedAsset unless that is address(0) (any asset). Not rate-limited — recipients are vetted
     * by the owner at set time — but a newly added recipient is time-locked by whitelistedProtection
     * until its window elapses. Paid from the vault's idle balance.
     */
    function sendToWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, address asset, uint256 amount)
        external
        onlyInitialized(vaultStorage)
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
        _checkPaymentRiskCap(vaultStorage, _effective(vaultStorage.riskConfig.maxWhitelistedValue), asset, amount);
        _requireProtectionElapsed(vaultStorage.whitelistedRecipientEffectiveAt[id]);
        _payOut(vaultStorage, asset, amount, entry.recipient);
        emit IBittyV1Owner.WhitelistedRecipientPaid(id, entry.recipient, asset, amount);
    }

    function getWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id)
        external
        view
        returns (address recipient, address allowedAsset)
    {
        IBittyV1Vault.WhitelistedRecipient memory entry = vaultStorage.whitelistedRecipients[id];
        return (entry.recipient, entry.allowedAsset);
    }

    function payScheduled(VaultStorage storage vaultStorage, uint256 id) external onlyInitialized(vaultStorage) {
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[id];
        if (scheduledPayment.trigger != address(0) && msg.sender != scheduledPayment.trigger) {
            revert ScheduledPaymentTriggerError();
        }
        _payScheduled(vaultStorage, scheduledPayment, id, scheduledPayment.amount);
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
        _payScheduled(vaultStorage, scheduledPayment, id, amount);
    }

    function _payScheduled(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment storage scheduledPayment,
        uint256 id,
        uint256 payAmount
    ) internal {
        if (_accrueScheduledPayment(vaultStorage, scheduledPayment, id)) {
            // Nothing to pay right now; the slot and interval were not consumed, so the payment stays due.
            return;
        }
        uint256 paidAmount = _transferMoney(
            vaultStorage,
            scheduledPayment.assetAddress,
            payAmount,
            scheduledPayment.scheduledPaymentAddress,
            scheduledPayment.payWithInsufficientBalance
        );
        emit IBittyV1Vault.ScheduledPaymentPaid(
            id,
            scheduledPayment.scheduledPaymentAddress,
            scheduledPayment.assetAddress,
            paidAmount,
            scheduledPayment.remainingPaymentCount
        );
    }

    /**
     * @dev Runs every eligibility check for a scheduled scheduledPayment payment and applies its
     * state effects (advance the interval clock, clear the new-scheduledPayment time-lock, and
     * consume one payment) — but performs no token transfer. Shared by the normal
     * pay-from-vault-balance path and the on-behalf pay-from-yield path so both honour
     * identical rules and checks-effects-interactions ordering.
     */
    /**
     * @dev Runs the validity checks (which revert), then either consumes a payment slot + advances the
     * interval clock, or — when the payment tolerates an insufficient balance and there is nothing to
     * pay — returns `true` to signal the caller to skip the transfer WITHOUT consuming a slot, so the
     * payment stays due and can be made once the vault is funded.
     */
    function _accrueScheduledPayment(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment storage scheduledPayment,
        uint256 id
    ) internal returns (bool skipped) {
        if (scheduledPayment.amount == 0) {
            revert ScheduledPaymentNotFound();
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
        // payee silently loses a whole period for a zero delivery.
        if (scheduledPayment.payWithInsufficientBalance) {
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
        // address(0) asset = pay in ETH; the vault holds it as WETH, so measure the balance in WETH.
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
     * arbitrary recipient, hence the reentrancy guard.
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

    function addAssets(VaultStorage storage vaultStorage, address[] memory assetAddresses)
        external
        onlyInitialized(vaultStorage)
    {
        if (vaultStorage.addingAssetsDisabled) {
            revert AddingAssetsDisabled();
        }
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (vaultStorage.guard.isAssetRegistered(assetAddresses[i])) {
                vaultStorage.assets.add(assetAddresses[i]);
            } else if (vaultStorage.guard.isStableCoinRegistered(assetAddresses[i])) {
                vaultStorage.stableCoins.add(assetAddresses[i]);
            } else {
                revert NotRegistered();
            }
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
