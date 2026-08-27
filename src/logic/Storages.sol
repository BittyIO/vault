// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

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

// Just the protocol. The flag that used to sit here said whether the route supplied or staked, which
// stopped meaning anything once both became one deposit call through IBittyV1Depositable.
struct AutoYieldConfig {
    address protocol;
}

struct AssetManagerStorage {
    bool isInitialized;

    mapping(address => address) clonedProtocols;

    address assetManager;

    uint64 assetManagerExpiresAt;

    mapping(address => bool) protocols;
    bool addingProtocolsDisabled;
    uint64 tradeDisabledUntilTimestamp;

    mapping(address => AutoYieldConfig) autoYieldConfigs;

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

struct VaultStorage {
    // One slot for the address and every flag beside it: 20 + 1 + 1 + 1 + 1 = 24 of 32 bytes. These
    // were spread over three slots, so a vault paid two extra cold SSTOREs at initialization to store
    // 4 bytes of state, and `weth` - read on every native-asset payout - was a slot of its own.
    address weth;
    bool isInitialized;
    bool addingAssetsDisabled;
    bool renounced;

    mapping(uint256 => IBittyV1Vault.ScheduledPayment) scheduledPayments;
    mapping(uint256 => uint256) lastReceiveTimestamps;
    mapping(uint256 => uint256) scheduledPaymentEffectiveAt;
    mapping(uint256 => uint256) whitelistedRecipientEffectiveAt;
    mapping(address => bool) assets;
    mapping(address => bool) stableCoins;
    RiskConfig riskConfig;

    mapping(address => bool) payoutOperators;

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
    // A singly linked list keyed entry -> next, circular through SENTINEL
    mapping(address => address) gaslessAssets;

    TimelockedValue maxFeePerOp;
}
