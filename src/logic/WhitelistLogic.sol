// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AddressZero,
    AmountIsZero,
    IBittyV1Vault,
    NoEscapeRecipient,
    WhitelistedRecipientNotFound,
    WhitelistEntryView,
    WHITELIST_REMOVED,
    WHITELIST_PENDING,
    WHITELIST_PAYABLE,
    WHITELIST_VOIDED,
    WHITELIST_REMOVAL_QUEUED
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {BittyStorage, Deferred, VaultStorage, WhitelistEntry} from "./BittyStorage.sol";
import {PaymentCore} from "./PaymentCore.sol";
import {LockLib} from "./LockLib.sol";
import {RiskLogic} from "./RiskLogic.sol";

/**
 * @title WhitelistLogic
 * @notice Whitelisted recipients: add / review / remove, and the protected payout to a pre-approved
 *         recipient. Split out of {PaymentLogic}; shares payout/protection via {PaymentCore}.
 *
 * @dev A whitelisted recipient is the owner's way out after a key leaks: a lock stops every other
 *      payment, but not these. So taking one away has to wait like granting one does. Were removal
 *      instant, the thief's first call would empty the list, and the forever lock that was meant to
 *      save the vault would instead seal the money in it.
 *
 *      Removing an entry the owner can already pay therefore queues, for the timelock in force, and
 *      the entry stays payable until then. A lock voids the queued removal by the same epoch stamp
 *      that voids a queued addition, so locking keeps every destination the owner already had.
 *      Nothing is lost by removing at once an entry nobody can pay yet — one still waiting out its
 *      own window, or voided by a lock — so those go immediately, as does everything on a vault with
 *      no timelock.
 *
 *      An entry is an address and nothing else: it accepts any asset the vault holds. A recipient
 *      held to one asset would strand every other one once the vault is locked, because a locked
 *      vault cannot trade into it — and this list is what a locked vault pays out through. Nor is
 *      there editing an entry in place: a new address is an addition and the old one a removal, and
 *      made together in one multicall the new becomes payable just as the old stops being.
 *
 *      The price is that a matured destination that should not be there cannot be struck off at
 *      once either. A thief who has one can pay to it whatever the rules on removal, so the owner's
 *      answer is the same as before: move the money to a destination of their own first.
 */
library WhitelistLogic {
    function addWhitelistedRecipientOne(address recipient) external returns (uint256 id) {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        if (recipient == address(0)) revert AddressZero();
        uint256 effectiveAt = PaymentCore.protectionDeadline(RiskLogic.effectiveTimelock(vaultStorage.riskConfig));
        id = ++vaultStorage.nextWhitelistedRecipientId;
        vaultStorage.whitelistedRecipient[id].recipient = recipient;
        vaultStorage.whitelistedRecipientDeferred[id] = Deferred({
            effectiveAt: uint64(effectiveAt), lockEpoch: effectiveAt == 0 ? LockLib.SETTLED : LockLib.lockEpoch()
        });
        emit IBittyV1Owner.WhitelistedRecipientSet(id, recipient);
    }

    /**
     * Refuse unless entry `id` can be paid right now — it exists, its own window has run, no lock voided
     * it and no removal of it has landed. Asked before the forever lock: once that is engaged nothing
     * can be added, so a vault locked with no payable recipient could never pay anything out again.
     * One named entry rather than a search of the list, so the check costs the same however many
     * entries a thief has queued.
     */
    function requireEscape(uint256 id) external view {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        WhitelistEntry memory entry = vaultStorage.whitelistedRecipient[id];
        if (entry.recipient == address(0) || _removed(entry)) revert NoEscapeRecipient();
        if (!_payable(vaultStorage.whitelistedRecipientDeferred[id])) revert NoEscapeRecipient();
    }

    function removeWhitelistedRecipients(uint256[] calldata ids) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        uint64 timelock = RiskLogic.effectiveTimelock(vaultStorage.riskConfig);
        for (uint256 i; i < ids.length; ++i) {
            _remove(vaultStorage, ids[i], timelock);
        }
        if (ids.length > 0) emit IBittyV1Owner.WhitelistedRecipientsRemoved(ids);
    }

    /**
     * Remove entry `id`: at once if the owner cannot pay it yet, otherwise queued behind the
     * timelock. A removal already queued starts over.
     */
    function _remove(VaultStorage storage vaultStorage, uint256 id, uint64 timelock) private {
        WhitelistEntry storage entry = vaultStorage.whitelistedRecipient[id];
        if (_settle(vaultStorage, id, entry) == address(0)) revert WhitelistedRecipientNotFound();

        if (!_payable(vaultStorage.whitelistedRecipientDeferred[id])) {
            delete vaultStorage.whitelistedRecipient[id];
            delete vaultStorage.whitelistedRecipientDeferred[id];
            return;
        }

        uint64 removeAt = uint64(block.timestamp) + timelock;
        entry.removeAt = removeAt;
        entry.removeEpoch = LockLib.lockEpoch();
        emit IBittyV1Owner.WhitelistedRecipientRemovalQueued(id, removeAt);
    }

    /**
     * Whether the owner can pay the entry as it stands: its window has run and no lock voided it.
     */
    function _payable(Deferred storage deferred) private view returns (bool) {
        uint64 effectiveAt = deferred.effectiveAt;
        return block.timestamp >= effectiveAt && LockLib.honoured(deferred.lockEpoch, effectiveAt);
    }

    /**
     * Whether a queued removal of `entry` has taken effect: its time has come and no lock voided it.
     */
    function _removed(WhitelistEntry memory entry) private view returns (bool) {
        uint64 removeAt = entry.removeAt;
        return removeAt != 0 && block.timestamp >= removeAt && LockLib.honoured(entry.removeEpoch, removeAt);
    }

    /**
     * Carry out the removal queued against `entry` once its time has come, or drop it if a lock
     * voided it. Returns the recipient as it now stands, zero once removed. Free when nothing is
     * queued.
     */
    function _settle(VaultStorage storage vaultStorage, uint256 id, WhitelistEntry storage entry)
        private
        returns (address)
    {
        uint64 removeAt = entry.removeAt;
        if (removeAt == 0 || block.timestamp < removeAt) return entry.recipient;
        if (!LockLib.honoured(entry.removeEpoch, removeAt)) {
            entry.removeAt = 0;
            entry.removeEpoch = 0;
            return entry.recipient;
        }
        delete vaultStorage.whitelistedRecipient[id];
        delete vaultStorage.whitelistedRecipientDeferred[id];
        return address(0);
    }

    function sendToWhitelistedRecipientOne(uint256 id, address asset, uint256 amount) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        address recipient = _sendToWhitelistedRecipient(vaultStorage, id, asset, amount);
        emit IBittyV1Owner.WhitelistedRecipientPaid(id, recipient, asset, amount);
    }

    function _sendToWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, address asset, uint256 amount)
        private
        returns (address recipient)
    {
        if (amount == 0) revert AmountIsZero();
        WhitelistEntry storage entry = vaultStorage.whitelistedRecipient[id];
        recipient = entry.recipient;
        if (entry.removeAt != 0) recipient = _settle(vaultStorage, id, entry);
        if (recipient == address(0)) revert WhitelistedRecipientNotFound();

        Deferred memory deferred = vaultStorage.whitelistedRecipientDeferred[id];
        PaymentCore.requireProtectionElapsed(deferred.effectiveAt);
        if (LockLib.requireHonoured(deferred.lockEpoch, deferred.effectiveAt)) {
            vaultStorage.whitelistedRecipientDeferred[id].lockEpoch = LockLib.SETTLED;
        }

        PaymentCore.payOut(vaultStorage, asset, amount, recipient);
    }

    /**
     * The entries as they stand; zeros for an entry that is gone, including one whose queued
     * removal has taken effect.
     */
    function getWhitelistedRecipients(uint256[] calldata ids) external view returns (address[] memory recipients) {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        recipients = new address[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            WhitelistEntry memory entry = vaultStorage.whitelistedRecipient[ids[i]];
            if (!_removed(entry)) recipients[i] = entry.recipient;
        }
    }

    /**
     * When each entry's queued removal takes effect; 0 where none is waiting.
     */
    function getWhitelistedRecipientRemovals(uint256[] calldata ids) external view returns (uint64[] memory removeAts) {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        removeAts = new uint64[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            WhitelistEntry memory entry = vaultStorage.whitelistedRecipient[ids[i]];
            if (block.timestamp < entry.removeAt && LockLib.honoured(entry.removeEpoch, entry.removeAt)) {
                removeAts[i] = entry.removeAt;
            }
        }
    }

    function getWhitelist(uint256 fromId, uint256 count)
        external
        view
        returns (uint256 lastId, WhitelistEntryView[] memory entries)
    {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        lastId = vaultStorage.nextWhitelistedRecipientId;
        if (fromId == 0) fromId = 1;
        if (fromId > lastId) return (lastId, entries);
        uint256 n = lastId - fromId + 1;
        if (count < n) n = count;
        entries = new WhitelistEntryView[](n);
        for (uint256 i; i < n; ++i) {
            entries[i] = _view(vaultStorage, fromId + i);
        }
    }

    /**
     * Mirrors the payout: a removal that has landed wins, then one still queued (the entry stays
     * payable until it lands), then a lock that voided the entry before it matured, then its window.
     */
    function _view(VaultStorage storage vaultStorage, uint256 id) private view returns (WhitelistEntryView memory v) {
        WhitelistEntry memory entry = vaultStorage.whitelistedRecipient[id];
        v.id = id;
        if (entry.recipient == address(0) || _removed(entry)) return v; // WHITELIST_REMOVED

        Deferred memory deferred = vaultStorage.whitelistedRecipientDeferred[id];
        v.recipient = entry.recipient;
        v.effectiveAt = deferred.effectiveAt;
        if (entry.removeAt != 0 && LockLib.honoured(entry.removeEpoch, entry.removeAt)) {
            v.removeAt = entry.removeAt;
            v.status = WHITELIST_REMOVAL_QUEUED;
        } else if (!LockLib.honoured(deferred.lockEpoch, deferred.effectiveAt)) {
            v.status = WHITELIST_VOIDED;
        } else if (block.timestamp < deferred.effectiveAt) {
            v.status = WHITELIST_PENDING;
        } else {
            v.status = WHITELIST_PAYABLE;
        }
    }
}
