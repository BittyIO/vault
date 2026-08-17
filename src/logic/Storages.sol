// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
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
    mapping(address => uint256) minimalBalances;

    address assetManager;

    EnumerableSet.AddressSet lendingProtocols;
    EnumerableSet.AddressSet stakingProtocols;
    EnumerableSet.AddressSet ammProtocols;
    EnumerableSet.AddressSet intentProtocols;

    IBittyV1Guard guard;
    bool addingProtocolsDisabled;
    uint64 rebalanceDisabledUntilTimestamp;

    mapping(address => AutoYieldConfig) autoYieldConfigs;

    address autoYieldTrigger;
}

struct PendingSend {
    address proposer;
    address[] recipients;
    address[] assets;
    uint256[] amounts;
}

struct VaultStorage {
    bool isInitialized;
    mapping(uint256 => IBittyV1Vault.ScheduledPayment) scheduledPayments;
    mapping(uint256 => uint256) lastReceiveTimestamps;
    mapping(uint256 => uint256) scheduledPaymentEffectiveAt;
    mapping(uint256 => uint256) whitelistedRecipientEffectiveAt;
    IBittyV1Guard guard;
    address weth;
    EnumerableSet.AddressSet assets;
    EnumerableSet.AddressSet stableCoins;
    bool addingAssetsDisabled;

    // Reentrancy lock: native-ETH payouts are the only path that .call's an arbitrary recipient.
    bool payingEth;

    // Set once by renounceVaultOwnership: an ownerless vault pays out only its
    // locked immutable scheduled payments (the owner's pre-committed rescue);
    // every other payment becomes inert. Avoids a clear-everything loop at
    // renounce, so an attacker can't grief it by inflating the payment count.
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

    uint128 ownerSendPeriodStart;
    uint256 ownerSentInPeriod;
}
