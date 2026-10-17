// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "../interfaces/IBittyV1Vault.sol";

/**
 * @title BittyStorage
 * @notice ERC-7201 namespaced storage. Two independent contexts, each pinned to a fixed keccak-derived
 *         slot so the layout survives UUPS upgrades.
 *
 * @dev Slots derived as `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~0xff`:
 *      - bitty.storage.vault.main     → VAULT_SLOT
 *      - bitty.storage.vault.defi     → DEFI_SLOT
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
 *      These rules bind from the first vault that holds somebody else's money, and NOT YET. There
 *      are no `__deprecated` placeholders in this file, and that is deliberate rather than an
 *      oversight: retired fields have been deleted outright while the only vaults in existence hold
 *      team funds that can be moved by hand. The cost is that a vault deployed on an earlier layout
 *      can no longer be upgraded onto this code — it would read the wrong slots, silently — which is
 *      a trade worth making exactly once, before launch.
 *
 *      After that the rules below are absolute, and deleting from the middle of a struct stops being
 *      tidying and becomes the silent corruption described above. Do not read the absence of
 *      placeholders here as a precedent.
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
 *      The mapping values here are {Deferred} and {WhitelistEntry}: each is pinned as above, by
 *      being the value of a mapping in {VaultStorage}.
 */
struct TimelockedValue {
    uint64 value;
    uint64 pending;
    uint64 pendingAt;
}

struct Deferred {
    uint64 effectiveAt;
    uint32 lockEpoch;
}

struct WhitelistEntry {
    address recipient;
    uint64 removeAt;
    uint32 removeEpoch;
}

struct RiskConfig {
    TimelockedValue timelock;
    TimelockedValue sendDailyAllowance;
    TimelockedValue marketTradeDailyLossAllowance;
}

struct ProtocolInstance {
    address clone;
    uint32 version;
}

struct DeFiStorage {
    mapping(bytes32 => ProtocolInstance) clonedProtocols;
    mapping(address => address) autoYieldProtocols;
    mapping(address => bool) assets;
    mapping(address => bool) protocols;
    address autoYieldTrigger;

    address assetManager;
    uint48 assetManagerExpiresAt;
    uint32 assetManagerPerms;
    bool hasPendingAssetManager;

    address pendingAssetManager;
    uint48 pendingAssetManagerAt;
    uint48 pendingAssetManagerExpiresAt;
    uint32 pendingAssetManagerPerms;

    mapping(address => mapping(address => uint32)) receiptTokenApproved; // clone => asset => the {ProtocolInstance.version}
}

struct VaultStorage {
    address gasWrapped;
    bool isInitialized;
    bool ownAllowListActive;

    mapping(uint256 => Deferred) whitelistedRecipientDeferred;
    mapping(uint256 => WhitelistEntry) whitelistedRecipient;
    RiskConfig riskConfig;
    uint256 nextWhitelistedRecipientId;
    uint64 ownerSendPeriodStart;
    uint128 ownerSentInPeriod;

    uint128 marketTradeLossInPeriod;
    uint64 marketTradePeriodStart;

    TimelockedValue gasBudgetDaily;
    TimelockedValue maxFeePerOp;
    uint96 gasSpentToday;
    uint64 gasBudgetDay;
    bool stableCoinAsGasDisabled;
    mapping(address => address) stableCoinAsGasAssets;

    uint8 lockLevel; // 0 none, 1 emergency (releasable), 2 forever. See {LockLib}.

    uint32 lockEpoch;

    uint40 ownershipReadyAt;

    address vaultOwner;
    mapping(uint32 => uint64) lockEpochClosedAt;
    address pendingOwner;
}

library BittyStorage {
    bytes32 internal constant VAULT_SLOT = 0x17e3e73c9899a2a21e7ae5b2fc286a77d4903c0979f27baf0730ce5db138e400;
    bytes32 internal constant DEFI_SLOT = 0xfcb7e45a818f0ecef03db92f5b6e7b2ed559effd8e9a1c8a33ce82a8fa3b9400;

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
}
