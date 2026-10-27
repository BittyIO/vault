// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyStorage, VaultStorage, DeFiStorage} from "./BittyStorage.sol";
import {TimelockLib} from "./TimelockLib.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {VaultLocked} from "../interfaces/IBittyV1Vault.sol";

/**
 * @title LockLib
 * @notice The two locks, and the sweep that makes them worth engaging.
 *
 * A locked vault keeps its owner. That is the whole design: the key is assumed to leak, and the
 * person it leaked from still needs to use their money afterwards, so a lock does not disable the
 * key — it shrinks what any holder of it can reach down to the box the owner drew in advance. Money
 * still leaves, but only to a destination vetted before the leak, or as a limit order that buys
 * stablecoins for this vault. Value may always come home. Nothing about the configuration moves in
 * EITHER direction, because taking away an option the owner still has is as much an attack as
 * granting one they never did.
 *
 * An emergency lock can be released and still lets the relayer take its fee. A forever lock can do
 * neither. Apart from that the two permit exactly the same things, so there is one gate, not two.
 *
 * Both are instant. A lock that could be queued would be a lock the thief could cancel with the
 * same key, and a release that had to be queued would leave the owner with no way to use their own
 * vault for the length of the delay — which an attacker would simply wait out.
 *
 * ── the sweep ────────────────────────────────────────────────────────────────────────────────────
 *
 * A thief spends their protection window queueing: destinations, a manager grant, looser limits.
 * The lock has to void all of it, and the size of "all of it" is the attacker's choice — nothing
 * caps how many entries a key can create. Walking the queue would therefore be the vulnerability:
 * queue past the block gas limit and the lock could never be engaged again, the owner's last
 * control disabled by the thing it defends against.
 *
 * So {engage} writes two words and contains no loop at all. It closes the current risk epoch, noting
 * the moment it did so, and starts a new one. Entries carry the epoch they were made in, and
 * {honoured} reads an entry as valid only while its epoch is current or if it had already matured
 * when that epoch closed. Nothing is deleted; the losers are unreachable, which is the same thing
 * to an attacker and free to the vault. Because each closing time is kept per epoch, an entry swept
 * once is swept for ever — a later lock cannot move a freeze line past its maturity and revive it.
 *
 * The same stamp voids a queued removal of a whitelisted recipient, which is how a lock keeps every
 * destination the owner already had: the removal never takes effect, and the entry stays payable.
 *
 * The handful of pending values that live in fixed slots — the risk scalars, the gas budget, the
 * manager grant — are cleared outright, since there is a fixed number of them. Clearing a
 * {TimelockedValue}'s pending half keeps every tightening, which had applied immediately, and drops
 * every loosening, which had not.
 *
 */
library LockLib {
    /**
     * An epoch stamp meaning "this entry's verdict is final, and it is honoured".
     *
     * Once an entry has survived a lock — matured before its own epoch closed — nothing can change
     * that: the closing time is written once and its maturity is in the past. Re-deriving it on every
     * later use costs a cold read of {lockEpochClosedAt} for the life of the entry, so the first use
     * that pays for the derivation records it here instead.
     *
     * Deliberately NOT the current epoch: re-stamping to {lockEpoch} goes stale again at the next
     * lock, and the write would be paid once per lock rather than once per entry.
     */
    uint32 internal constant SETTLED = type(uint32).max;

    uint8 internal constant NONE = 0;
    uint8 internal constant EMERGENCY = 1;
    uint8 internal constant FOREVER = 2;

    function level() internal view returns (uint8) {
        return BittyStorage.vault().lockLevel;
    }

    function lockedForever() internal view returns (bool) {
        return BittyStorage.vault().lockLevel == FOREVER;
    }

    function requireNotLocked() internal view {
        if (BittyStorage.vault().lockLevel != NONE) revert VaultLocked();
    }

    function emergencyLock() internal {
        VaultStorage storage $ = BittyStorage.vault();
        if ($.lockLevel != NONE) revert VaultLocked();
        _engage($, EMERGENCY);
    }

    function foreverLock() internal {
        VaultStorage storage $ = BittyStorage.vault();
        if ($.lockLevel == FOREVER) revert VaultLocked();
        _engage($, FOREVER);
    }

    function unlock() internal {
        VaultStorage storage $ = BittyStorage.vault();
        if ($.lockLevel != EMERGENCY) revert VaultLocked();
        $.lockLevel = NONE;
        emit IBittyV1Owner.LockLevelSet(NONE, $.lockEpoch);
    }

    function _engage(VaultStorage storage $, uint8 next) private {
        uint32 closing = $.lockEpoch;
        $.lockEpochClosedAt[closing] = uint64(block.timestamp);
        $.lockEpoch = closing + 1;
        $.lockLevel = next;

        TimelockLib.cancelPending($.riskConfig.timelock);
        TimelockLib.cancelPending($.riskConfig.sendDailyAllowance);
        TimelockLib.cancelPending($.riskConfig.marketTradeDailyLossAllowance);
        TimelockLib.cancelPending($.gasBudgetDaily);
        TimelockLib.cancelPending($.maxFeePerOp);

        uint40 readyAt = $.ownershipReadyAt;
        if (readyAt != 0 && block.timestamp < readyAt) {
            $.ownershipReadyAt = 0;
            $.pendingOwner = address(0);
        }

        DeFiStorage storage d = BittyStorage.defi();
        if (d.hasPendingAssetManager) {
            if (block.timestamp >= d.pendingAssetManagerAt) {
                d.assetManager = d.pendingAssetManager;
                d.assetManagerExpiresAt = d.pendingAssetManagerExpiresAt;
                d.assetManagerPerms = d.pendingAssetManagerPerms;
            }
            d.pendingAssetManager = address(0);
            d.pendingAssetManagerExpiresAt = 0;
            d.pendingAssetManagerAt = 0;
            d.pendingAssetManagerPerms = 0;
            d.hasPendingAssetManager = false;
        }

        emit IBittyV1Owner.LockLevelSet(next, closing);
    }

    function lockEpoch() internal view returns (uint32) {
        return BittyStorage.vault().lockEpoch;
    }

    function requireHonoured(uint32 entryEpoch, uint256 maturity) internal view returns (bool settle) {
        VaultStorage storage $ = BittyStorage.vault();
        if (entryEpoch == $.lockEpoch) return false; // may yet go stale; nothing final to record
        if (entryEpoch == SETTLED) return false; // already recorded
        if (maturity > $.lockEpochClosedAt[entryEpoch]) revert VaultLocked();
        return true;
    }

    /**
     * {requireHonoured} as a question rather than a gate: false for an entry a lock has voided.
     * Says nothing about whether `maturity` has come — an entry of the current epoch is honoured
     * however far off it is.
     */
    function honoured(uint32 entryEpoch, uint256 maturity) internal view returns (bool) {
        VaultStorage storage $ = BittyStorage.vault();
        if (entryEpoch == SETTLED || entryEpoch == $.lockEpoch) return true;
        return maturity <= $.lockEpochClosedAt[entryEpoch];
    }
}
