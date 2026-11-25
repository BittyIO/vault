// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AddressZero,
    AmountIsZero,
    IBittyV1Vault,
    NoEscapeRecipient,
    WhitelistedRecipientNotFound,
    WhitelistedRecipientWrongChain,
    WhitelistedRecipientIsVault,
    RecipientNotAnAddress,
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
import {ANY_EVM_CHAIN, EVM_CHAIN_KEY, BITTY_GUARD} from "./Constants.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";

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
 *      An entry may name another chain ({addWhitelistedRecipientOn}): an address there, which the
 *      vault reaches only by a bridge. Every payout here refuses such an entry, since the same 20
 *      bytes on this chain need not be anyone's, and so does the forever lock's escape check, since
 *      the bridge it would need (the switch, the adapter, the route) can go away under a lock. Or
 *      it may name every EVM chain ({ANY_EVM_CHAIN}): the same address here, paid like an entry
 *      here and an escape like one, and on any EVM chain a bridge reaches.
 *
 *      The price is that a matured destination that should not be there cannot be struck off at
 *      once either. A thief who has one can pay to it whatever the rules on removal, so the owner's
 *      answer is the same as before: move the money to a destination of their own first.
 */
library WhitelistLogic {
    function addWhitelistedRecipientOne(address recipient) external returns (uint256 id) {
        id = _add(recipient);
        emit IBittyV1Owner.WhitelistedRecipientSet(id, recipient);
    }

    /**
     * An entry on `chainId`, or on every EVM chain for {ANY_EVM_CHAIN}, under the same protection
     * window as one here. `recipient` is 32 bytes so a Solana address fits; one here or on every
     * EVM chain must be a 20-byte address. This chain's own id makes an ordinary entry. The
     * vault's own address is refused: on another EVM chain it is the vault's counterpart, which
     * {IBittyV1DeFi-bridge} already reaches, and on TRON no one's.
     *
     * A 32-byte address keeps its low 20 bytes in the entry, so every existing check reads the
     * entry as present, and the whole of it beside; one whose low 20 bytes are all zero is refused,
     * which no real key's address is.
     */
    function addWhitelistedRecipientOn(uint256 chainId, bytes32 recipient) external returns (uint256 id) {
        address low = address(uint160(uint256(recipient)));
        bool wide = uint256(recipient) >> 160 != 0;
        if (chainId == 0 || chainId == block.chainid) {
            if (wide) revert RecipientNotAnAddress();
            id = _add(low);
            emit IBittyV1Owner.WhitelistedRecipientSet(id, low);
            return id;
        }
        if (wide && chainId == ANY_EVM_CHAIN) revert RecipientNotAnAddress();
        if (!wide && low == address(this)) revert WhitelistedRecipientIsVault();
        id = _add(low);
        VaultStorage storage vaultStorage = BittyStorage.vault();
        vaultStorage.whitelistedRecipientChain[id] = chainId;
        if (wide) vaultStorage.whitelistedRecipientAccount[id] = recipient;
        emit IBittyV1Owner.WhitelistedRecipientSetOn(id, chainId, recipient);
    }

    /**
     * Entry `id`'s address on its chain, as 32 bytes.
     */
    function _account(VaultStorage storage vaultStorage, uint256 id, address recipient)
        private
        view
        returns (bytes32 account)
    {
        account = vaultStorage.whitelistedRecipientAccount[id];
        if (account == 0) account = bytes32(uint256(uint160(recipient)));
    }

    function _add(address recipient) private returns (uint256 id) {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        if (recipient == address(0)) revert AddressZero();
        uint256 effectiveAt = PaymentCore.protectionDeadline(RiskLogic.effectiveTimelock(vaultStorage));
        id = ++vaultStorage.nextWhitelistedRecipientId;
        vaultStorage.whitelistedRecipient[id].recipient = recipient;
        vaultStorage.whitelistedRecipientDeferred[id] = Deferred({
            effectiveAt: uint64(effectiveAt), lockEpoch: effectiveAt == 0 ? LockLib.SETTLED : LockLib.lockEpoch()
        });
    }

    /**
     * Refuse unless entry `id` can be paid right now — it exists, its own window has run, no lock voided
     * it and no removal of it has landed. Asked before the forever lock: once that is engaged nothing
     * can be added, so a vault locked with no payable recipient could never pay anything out again.
     * The vault itself is no way out either: paying it moves nothing, so it is refused like a missing
     * entry, and so is one on another chain. One named entry rather than a search of the list, so
     * the check costs the same however many entries a thief has queued.
     */
    function requireEscape(uint256 id) external view {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        WhitelistEntry memory entry = vaultStorage.whitelistedRecipient[id];
        if (
            entry.recipient == address(0) || entry.recipient == address(this) || _removed(entry)
                || !_here(vaultStorage.whitelistedRecipientChain[id])
        ) {
            revert NoEscapeRecipient();
        }
        if (!_payable(vaultStorage.whitelistedRecipientDeferred[id])) revert NoEscapeRecipient();
    }

    function removeWhitelistedRecipients(uint256[] calldata ids) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        uint64 timelock = RiskLogic.effectiveTimelock(vaultStorage);
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
            _delete(vaultStorage, id);
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
        _delete(vaultStorage, id);
        return address(0);
    }

    function _delete(VaultStorage storage vaultStorage, uint256 id) private {
        delete vaultStorage.whitelistedRecipient[id];
        delete vaultStorage.whitelistedRecipientDeferred[id];
        if (vaultStorage.whitelistedRecipientChain[id] != 0) {
            delete vaultStorage.whitelistedRecipientChain[id];
            delete vaultStorage.whitelistedRecipientAccount[id];
        }
    }

    function sendToWhitelistedRecipientOne(uint256 id, address asset, uint256 amount) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        address recipient = _sendToWhitelistedRecipient(vaultStorage, id, asset, amount);
        emit IBittyV1Owner.WhitelistedRecipientPaid(id, recipient, asset, amount);
    }

    /**
     * The address entry `id` pays to, if it can be paid right now — the same test every payout to a
     * whitelisted recipient passes, for assets the vault hands over itself (an ERC-721) rather than
     * through {PaymentCore-payOut}. Settles a landed removal and records a verdict a lock made final,
     * exactly as a payout does.
     */
    function payableRecipient(uint256 id) external returns (address recipient) {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        return _payableHere(vaultStorage, id);
    }

    /**
     * The address entry `id` pays to on `destinationChainId`, if it is on that chain (or on every
     * EVM chain, and that one is EVM) and can be paid right now: the same test as
     * {payableRecipient}, for the bridge that pays it. Which chains a bridge can reach at all is
     * the guard's routes' to say, and which of them are EVM the guard's {EVM_CHAIN_KEY} marks.
     */
    function payableRecipientOn(uint256 id, uint256 destinationChainId) external returns (bytes32 recipient) {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        uint256 chainId = vaultStorage.whitelistedRecipientChain[id];
        bool reaches = chainId == ANY_EVM_CHAIN
            ? IBittyV1Guard(BITTY_GUARD).getUint(keccak256(abi.encode(EVM_CHAIN_KEY, destinationChainId))) == 1
            : chainId != 0 && chainId == destinationChainId;
        if (!reaches || destinationChainId == block.chainid) revert WhitelistedRecipientWrongChain();
        recipient = _account(vaultStorage, id, _payableRecipient(vaultStorage, id));
    }

    /**
     * Whether an entry on `chainId` is paid on this chain: one here, or one on every EVM chain.
     */
    function _here(uint256 chainId) private pure returns (bool) {
        return chainId == 0 || chainId == ANY_EVM_CHAIN;
    }

    function _sendToWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, address asset, uint256 amount)
        private
        returns (address recipient)
    {
        if (amount == 0) revert AmountIsZero();
        recipient = _payableHere(vaultStorage, id);
        PaymentCore.payOut(vaultStorage, asset, amount, recipient);
    }

    /**
     * {_payableRecipient} for a payout on this chain, which an entry on another chain never takes.
     */
    function _payableHere(VaultStorage storage vaultStorage, uint256 id) private returns (address) {
        if (!_here(vaultStorage.whitelistedRecipientChain[id])) revert WhitelistedRecipientWrongChain();
        return _payableRecipient(vaultStorage, id);
    }

    function _payableRecipient(VaultStorage storage vaultStorage, uint256 id) private returns (address recipient) {
        WhitelistEntry storage entry = vaultStorage.whitelistedRecipient[id];
        recipient = entry.recipient;
        if (entry.removeAt != 0) recipient = _settle(vaultStorage, id, entry);
        if (recipient == address(0)) revert WhitelistedRecipientNotFound();

        Deferred memory deferred = vaultStorage.whitelistedRecipientDeferred[id];
        PaymentCore.requireProtectionElapsed(deferred.effectiveAt);
        if (LockLib.requireHonoured(deferred.lockEpoch, deferred.effectiveAt)) {
            vaultStorage.whitelistedRecipientDeferred[id].lockEpoch = LockLib.SETTLED;
        }
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
        v.chainId = vaultStorage.whitelistedRecipientChain[id];
        v.account = _account(vaultStorage, id, entry.recipient);
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
