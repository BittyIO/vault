// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "../interfaces/IBittyV1Vault.sol";

/**
 * @title BittyStorage
 * @notice ERC-7201 namespaced storage for the subaccount generation. Three independent contexts, each
 *         pinned to a fixed keccak-derived slot so the layout survives UUPS upgrades and so the shared
 *         {BittyV1VaultDeFiFacet} reads the right {DeFiStorage} whether it runs inside the main vault or
 *         a sub vault.
 *
 * @dev Slots derived as `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~0xff`:
 *      - bitty.storage.vault.main     → VAULT_SLOT
 *      - bitty.storage.vault.defi     → DEFI_SLOT   (one per DeFi context: the main vault's, and each sub's)
 *      - bitty.storage.vault.subvault → SUBVAULT_SLOT
 *
 *      The ids carry NO version, and that is the point. An id is not a label for a release — it is the
 *      address of the data. `keccak256("bitty.storage.vault.main")` is what produces VAULT_SLOT, so
 *      changing a single character of it moves the root: an upgraded implementation would find
 *      untouched zeros at the new slot and report every vault as uninitialised, while the real state
 *      sat intact at the old one with nothing left that knew its number.
 *
 *      So these three strings must survive every future version of this contract. v1.1, v2, whatever
 *      comes — same address, same data, same ids. The only reason to mint a new id is to open a
 *      deliberately separate region, which is a new deployment rather than an upgrade; migrating in
 *      place would mean carrying the second namespace ALONGSIDE the first and copying between them,
 *      never renaming this one.
 *
 *      ── BEFORE SHIPPING AN UPGRADE, CHECK EVERY STRUCT IN THIS FILE ──────────────────────────────
 *
 *      An upgrade replaces the code and keeps the storage. Nothing on chain records what the old
 *      layout was, so the new implementation is simply believed: get a field's position wrong and it
 *      reads a neighbour's bytes as its own. No revert, no event, no way back except another upgrade —
 *      and by then the wrong values have already been written.
 *
 *      Safe:
 *        - APPEND a field to the end of a struct. It lands on slots that were untouched zeros.
 *        - REMOVE the last field. Nothing below it shifts; the slot goes unread.
 *        - Rename a field or a Solidity identifier. Names are compile-time only.
 *
 *      Never, on a struct that already holds live data:
 *        - Insert or reorder a field. Everything after it shifts by a slot.
 *        - Delete from the middle. Same shift, and silent.
 *        - Change a type where it alters packing (uint64 → uint128 can repack the whole slot, and a
 *          value type ↔ mapping is a different thing entirely).
 *
 *      Which structs this applies to is the part that is easy to get wrong, so each is marked below.
 *      It is NOT only the three namespace roots: a struct used as a mapping VALUE is just as pinned,
 *      because its fields sit at consecutive slots from `keccak256(key . position)`. Those are the
 *      dangerous ones — nothing next to them says `$.slot :=` to remind you.
 *
 *      Two mapping values live in another file and so are not marked here at all:
 *      {IBittyV1Vault.ScheduledPayment} and {IBittyV1Vault.WhitelistedRecipient}. They carry the same
 *      constraint and are the likeliest to be edited by someone who never opens this file.
 */
struct TimelockedValue {
    uint64 value;
    uint64 pending;
    uint64 pendingAt;
}

struct RiskConfig {
    TimelockedValue newPaymentProtection;
    TimelockedValue maxSendValue;
    TimelockedValue maxSendInterval;
    TimelockedValue changeTimelock;
}

struct PendingSend {
    address proposer;
    address[] recipients;
    address[] assets;
    uint256[] amounts;
}

struct SubVaultEntry {
    address account;
    address owner;
    bool closed;
    uint64 expiresAt;
    bool gaslessEnabled;
}

struct DeFiStorage {
    bool isInitialized;
    bool allowlistEnabled;
    uint64 allowlistDisableAt;
    uint64 tradeDisabledUntilTimestamp;
    mapping(address => address) clonedProtocols;
    mapping(address => address) autoYieldProtocols;
    mapping(address => bool) assets;
    mapping(address => bool) protocols;
    address autoYieldTrigger;
    address assetManager;
    uint64 assetManagerExpiresAt;
    address pendingAssetManager;
    uint64 pendingAssetManagerExpiresAt;
    uint64 pendingAssetManagerAt; // 0 = nothing queued
}

struct VaultStorage {
    address weth;
    bool isInitialized;
    bool renounced;

    mapping(uint256 => IBittyV1Vault.ScheduledPayment) scheduledPayments;
    mapping(uint256 => uint256) lastReceiveTimestamps;
    mapping(uint256 => uint256) scheduledPaymentEffectiveAt;
    mapping(uint256 => uint256) whitelistedRecipientEffectiveAt;
    mapping(uint256 => IBittyV1Vault.WhitelistedRecipient) whitelistedRecipients;
    mapping(uint256 => address) scheduledPaymentPendingProposer;
    mapping(uint256 => address) whitelistedRecipientPendingProposer;
    mapping(uint256 => PendingSend) pendingSends;
    mapping(address => bool) payoutOperators;
    RiskConfig riskConfig;
    uint256 nextPendingSendId;
    uint256 nextScheduledPaymentId;
    uint256 nextWhitelistedRecipientId;
    uint64 ownerSendPeriodStart;
    uint128 ownerSentInPeriod;

    TimelockedValue gasBudgetDaily;
    TimelockedValue maxFeePerOp;
    uint96 gasSpentToday;
    uint64 gasBudgetDay;
    bool gaslessDisabled;
    mapping(address => address) gaslessAssets;

    mapping(uint256 => SubVaultEntry) subs;
    uint256 nextSubId;
    uint256 openSubCount;
}

struct SubVaultStorage {
    address vault;
    address subOwner;
    bool isInitialized;
    bool gaslessEnabled;
    uint64 gasDailyLimit;
    uint64 maxFeePerOp;
    uint96 gasSpentToday;
    uint64 gasBudgetDay;
    uint64 subOwnerExpiresAt;
}

library BittyStorage {
    bytes32 internal constant VAULT_SLOT = 0x17e3e73c9899a2a21e7ae5b2fc286a77d4903c0979f27baf0730ce5db138e400;
    bytes32 internal constant DEFI_SLOT = 0xfcb7e45a818f0ecef03db92f5b6e7b2ed559effd8e9a1c8a33ce82a8fa3b9400;
    bytes32 internal constant SUBVAULT_SLOT = 0x1f23b54053e98ff84aecab4159c83dbe1d91d3e7726b98f9dbe948133c43d300;

    function vault() internal pure returns (VaultStorage storage $) {
        assembly {
            $.slot := VAULT_SLOT
        }
    }

    function defi() internal pure returns (DeFiStorage storage $) {
        assembly {
            $.slot := DEFI_SLOT
        }
    }

    function subVault() internal pure returns (SubVaultStorage storage $) {
        assembly {
            $.slot := SUBVAULT_SLOT
        }
    }
}
