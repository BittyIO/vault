// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IBittyV1Vault} from "../interfaces/IBittyV1Vault.sol";

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

struct AutoYieldConfig {
    address protocol;
    bool isSupplying;
}

struct AssetManagerStorage {
    bool isInitialized;

    mapping(address => address) clonedProtocols;

    address assetManager;

    uint64 assetManagerExpiresAt;

    EnumerableSet.AddressSet protocols;
    bool addingProtocolsDisabled;
    uint64 rebalanceDisabledUntilTimestamp;

    mapping(address => AutoYieldConfig) autoYieldConfigs;

    /**
     * @notice A scheduled asset-manager change, waiting out the vault's `changeTimelock`.
     * @dev Installing a manager is the LOOSENING direction — it hands trading authority to another
     *      key — so it waits, exactly like widening a payment limit does. Revoking, and shortening an
     *      existing grant, stay immediate: those are the moments an owner must not be made to wait.
     *
     *      `pendingAssetManagerAt` is 0 when nothing is scheduled. Once `block.timestamp` reaches it
     *      the pending grant IS the live one, whether or not anything has settled it to storage —
     *      the same read-through rule {TimelockedValue} uses, so authority never depends on someone
     *      having sent a transaction to finalise it.
     */
    address pendingAssetManager;
    uint64 pendingAssetManagerExpiresAt;
    uint64 pendingAssetManagerAt;
}

struct PendingSend {
    address proposer;
    address[] recipients;
    address[] assets;
    uint256[] amounts;
}

/**
 * @dev Shared by {BittyV1Vault} and {BittyV1VaultDeFiFacet}: the facet is delegatecalled, so it runs
 *      its own compiled slot numbers against the vault's storage. ALWAYS APPEND new fields to the end
 *      of this struct — inserting one shifts every later field, and the facet reads `trustedForwarder`
 *      from here to decide whether an appended ERC-2771 sender is trustworthy. A misaligned read of
 *      that field would not fail loudly; it would change who the vault believes is calling.
 *      Appending keeps a mismatched (older) facet fail-closed instead.
 */
struct VaultStorage {
    bool isInitialized;
    mapping(uint256 => IBittyV1Vault.ScheduledPayment) scheduledPayments;
    mapping(uint256 => uint256) lastReceiveTimestamps;
    mapping(uint256 => uint256) scheduledPaymentEffectiveAt;
    mapping(uint256 => uint256) whitelistedRecipientEffectiveAt;
    address weth;
    EnumerableSet.AddressSet assets;
    EnumerableSet.AddressSet stableCoins;
    bool addingAssetsDisabled;

    bool renounced;
    RiskConfig riskConfig;

    EnumerableSet.AddressSet payoutOperators;

    mapping(uint256 => IBittyV1Vault.WhitelistedRecipient) whitelistedRecipients;

    mapping(uint256 => address) scheduledPaymentPendingProposer;
    mapping(uint256 => address) whitelistedRecipientPendingProposer;

    mapping(uint256 => PendingSend) pendingSends;
    uint256 nextPendingSendId;

    uint256 nextScheduledPaymentId;
    uint256 nextWhitelistedRecipientId;

    // Packed into one slot, so the rolling-quota update is a single SSTORE. `ownerSentInPeriod` is
    // an 18-decimal value bounded by maxSendValue * 1e18, and maxSendValue is a uint64 — so the most
    // it can hold is ~1.8e37, well inside uint128.
    uint64 ownerSendPeriodStart;
    uint128 ownerSentInPeriod;

    TimelockedValue gasBudgetDaily;
    uint96 gasSpentToday;
    uint64 gasBudgetDay;
    bool gaslessDisabled;
    EnumerableSet.AddressSet gaslessStableCoins;

    TimelockedValue maxFeePerOp;
}
