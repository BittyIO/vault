// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AddressZero,
    AmountIsZero,
    ArrayLengthMismatch,
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
    AssetAddressNotContract,
    PayMoreThanScheduledPaymentAmount,
    PayScheduledPaymentAmountTriggerEmpty,
    PaymentNotApproved,
    NotPendingApproval,
    NotProposalOwner,
    ScheduledPaymentContentMismatch
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {IBittyV1PayoutOperator} from "../interfaces/IBittyV1PayoutOperator.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {BittyStorage, VaultStorage} from "./BittyStorage.sol";
import {PaymentCore} from "./PaymentCore.sol";
import {TimelockLib} from "./TimelockLib.sol";

/**
 * @title ScheduledPaymentLogic
 * @notice Scheduled payments: add / update / review / remove, and the accrual + payout the main vault
 *         drives (including the position-funded top-up split). Split out of {PaymentLogic}; shares the
 *         payout/protection primitives via {PaymentCore}.
 */
library ScheduledPaymentLogic {
    function addScheduledPaymentOne(
        IBittyV1Vault.ScheduledPayment calldata scheduledPayment,
        bool byOwner,
        address sender
    ) external returns (uint256 id) {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        uint64 protection = TimelockLib.effective(vaultStorage.riskConfig.newPaymentProtection);
        id = _addScheduledPayment(
            vaultStorage,
            scheduledPayment,
            byOwner,
            PaymentCore.protectionDeadline(protection),
            PaymentCore.immutableLockDeadlineFromWindow(protection),
            sender
        );
        emit IBittyV1PayoutOperator.ScheduledPaymentAdded(id, scheduledPayment);
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
        uint256[] calldata ids,
        IBittyV1Vault.ScheduledPayment[] calldata scheduledPayments,
        bool byOwner,
        address sender
    ) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        if (ids.length != scheduledPayments.length) revert ArrayLengthMismatch();
        uint64 protection = TimelockLib.effective(vaultStorage.riskConfig.newPaymentProtection);
        uint256 protectionDeadline = PaymentCore.protectionDeadline(protection);
        uint256 immutableDeadline = PaymentCore.immutableLockDeadlineFromWindow(protection);
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
        if (existing.recipient == address(0)) revert ScheduledPaymentNotFound();
        if (existing.isImmutable) revert ScheduledPaymentImmutable();
        if (byOwner) {
            delete vaultStorage.scheduledPaymentPendingProposer[id];
        } else if (vaultStorage.scheduledPaymentPendingProposer[id] != sender) {
            revert NotProposalOwner();
        }
        _checkScheduledPayment(scheduledPayment);
        vaultStorage.scheduledPayments[id] = scheduledPayment;
        uint256 effectiveAt = protectionDeadline;
        if (byOwner && scheduledPayment.isImmutable) effectiveAt = immutableDeadline;
        vaultStorage.scheduledPaymentEffectiveAt[id] = effectiveAt;
    }

    function reviewScheduledPayments(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds,
        address sender
    ) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        if (approveIds.length != expectedHashes.length) revert ArrayLengthMismatch();
        uint256 immutableDeadline = PaymentCore.immutableLockDeadlineFromWindow(
            TimelockLib.effective(vaultStorage.riskConfig.newPaymentProtection)
        );
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
        if (scheduledPayment.amount == 0) revert ScheduledPaymentNotFound();
        if (vaultStorage.scheduledPaymentPendingProposer[id] == address(0)) revert NotPendingApproval();
        if (keccak256(abi.encode(scheduledPayment)) != expectedHash) revert ScheduledPaymentContentMismatch();
        delete vaultStorage.scheduledPaymentPendingProposer[id];
        if (scheduledPayment.isImmutable) vaultStorage.scheduledPaymentEffectiveAt[id] = immutableDeadline;
    }

    function _checkScheduledPayment(IBittyV1Vault.ScheduledPayment calldata scheduledPayment) private view {
        if (scheduledPayment.recipient == address(0)) revert AddressZero();
        if (scheduledPayment.assetAddress != address(0) && scheduledPayment.assetAddress.code.length == 0) {
            revert AssetAddressNotContract();
        }
        if (scheduledPayment.amount == 0) revert AmountIsZero();
        if (scheduledPayment.remainingPaymentCount == 0) revert ScheduledPaymentPaymentCountZero();
    }

    function removeScheduledPayments(uint256[] calldata ids, bool byOwner, address sender) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        for (uint256 i; i < ids.length; ++i) {
            _removeScheduledPayment(vaultStorage, ids[i], byOwner, sender);
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.ScheduledPaymentsRemoved(ids);
    }

    function _removeScheduledPayment(VaultStorage storage vaultStorage, uint256 id, bool byOwner, address sender)
        private
    {
        if (!byOwner && vaultStorage.scheduledPaymentPendingProposer[id] != sender) revert NotProposalOwner();
        if (PaymentCore.isLockedImmutable(vaultStorage, id)) revert ImmutableScheduledPaymentLocked();
        delete vaultStorage.scheduledPayments[id];
        delete vaultStorage.scheduledPaymentPendingProposer[id];
        delete vaultStorage.lastReceiveTimestamps[id];
        delete vaultStorage.scheduledPaymentEffectiveAt[id];
    }

    function accrueScheduled(uint256 id, address sender, bool hasProtocols)
        external
        returns (
            bool skipped,
            address recipient,
            address asset,
            address payoutToken,
            uint256 needed,
            uint256 have,
            bool allowPartial,
            uint256 count
        )
    {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        IBittyV1Vault.ScheduledPayment storage sp = vaultStorage.scheduledPayments[id];
        if (sp.trigger != address(0) && sender != sp.trigger) revert ScheduledPaymentTriggerError();
        if (_accrueScheduledPayment(vaultStorage, sp, id, hasProtocols)) {
            return (true, address(0), address(0), address(0), 0, 0, false, 0);
        }
        recipient = sp.recipient;
        asset = sp.assetAddress;
        payoutToken = asset == address(0) ? vaultStorage.weth : asset;
        needed = sp.amount;
        have = IERC20(payoutToken).balanceOf(address(this));
        allowPartial = sp.payWithInsufficientBalance;
        count = sp.remainingPaymentCount;
    }

    function payScheduledOut(address asset, address recipient, uint256 amount) external {
        PaymentCore.payOut(BittyStorage.vault(), asset, amount, recipient);
    }

    function payScheduledAmount(uint256 id, uint256 amount, address sender) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[id];
        if (scheduledPayment.amount < amount) revert PayMoreThanScheduledPaymentAmount();
        if (scheduledPayment.trigger == address(0)) revert PayScheduledPaymentAmountTriggerEmpty();
        if (sender != scheduledPayment.trigger) revert ScheduledPaymentTriggerError();
        (bool skipped, address addr, address asset, uint256 paid, uint256 count) =
            _payScheduled(vaultStorage, scheduledPayment, id, amount);
        if (!skipped) emit IBittyV1Vault.ScheduledPaymentPaid(id, addr, asset, paid, count);
    }

    function _payScheduled(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment storage scheduledPayment,
        uint256 id,
        uint256 payAmount
    )
        private
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
        paidAmount = PaymentCore.transferMoney(
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
    ) private returns (bool skipped) {
        if (scheduledPayment.amount == 0) revert ScheduledPaymentNotFound();
        if (vaultStorage.renounced && !PaymentCore.isLockedImmutable(vaultStorage, id)) {
            revert OnlyImmutablePayableAfterRenounce();
        }
        if (vaultStorage.scheduledPaymentPendingProposer[id] != address(0)) revert PaymentNotApproved();
        if (scheduledPayment.remainingPaymentCount == 0) revert ScheduledPaymentPaymentCountZero();
        if (scheduledPayment.startTimestamp > block.timestamp) revert ScheduledPaymentNotStartYet();
        if (
            scheduledPayment.paymentInterval != 0 && vaultStorage.lastReceiveTimestamps[id] > 0
                && block.timestamp - vaultStorage.lastReceiveTimestamps[id] < scheduledPayment.paymentInterval
        ) revert ScheduledPaymentInInterval();
        PaymentCore.requireProtectionElapsed(vaultStorage.scheduledPaymentEffectiveAt[id]);

        if (!fromPosition && scheduledPayment.payWithInsufficientBalance) {
            address balanceToken =
                scheduledPayment.assetAddress == address(0) ? vaultStorage.weth : scheduledPayment.assetAddress;
            if (IERC20(balanceToken).balanceOf(address(this)) == 0) return true;
        }

        vaultStorage.lastReceiveTimestamps[id] = block.timestamp;
        if (scheduledPayment.remainingPaymentCount != type(uint256).max) {
            scheduledPayment.remainingPaymentCount = scheduledPayment.remainingPaymentCount - 1;
        }
    }
}
