// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1Vault, RiskControlLevel} from "../interfaces/IBittyV1Vault.sol";

struct IntentOrderRecord {
    address sellToken; // address(0) = no record
    uint96 expiresAt; // packs with sellToken into one slot; timestamp fits easily
    // Intent protocol this order was placed through; a cancel must pass the same protocol.
    address owningProtocol;
    // Whole-token stablecoin this order counted against stableCoinInvestCap at placement (0 = none: a
    // divest, a full-access manager, or a TWAP). Refunded to stableCoinInvested on cancel/expiry if the
    // order never filled (fill-or-kill, so an unfilled order deployed nothing). Packs with owningProtocol.
    uint64 investedCounted;
    // Amount of sellToken this open order reserves; released from committedIntentSell on cancel/expiry.
    uint256 reservedSell;
}

// A risk parameter whose value the owner may freely change, but a LOOSENING change (one that would
// increase losses if the owner key were compromised) only takes effect after `changeTimelock` seconds;
// a tightening change is immediate. `pendingAt == 0` means no change is queued.
struct TimelockedValue {
    uint64 value; // current in-force value
    uint64 pending; // queued (looser) value awaiting its delay
    uint64 pendingAt; // unix time when `pending` becomes effective (0 = none)
}

// Payment risk controls (payments only; trading limits live in AssetManagerSettings). Not tighten-only: the
// owner may set any value, but loosening is delayed by `changeTimelock` (see TimelockedValue).
struct RiskConfig {


    TimelockedValue scheduledPaymentProtection;
    TimelockedValue whitelistedProtection;

    TimelockedValue maxSendValue;
    TimelockedValue maxScheduledValue;
    TimelockedValue maxWhitelistedValue;

    TimelockedValue changeTimelock;

    TimelockedValue maxSendInterval;
}

struct AssetManagerSettings {
    uint64 interval; // 0 = no limit
    uint64 maxStableCoinPerTrade; // 0 = no cap
    uint64 stableCoinInvestCap; // guardrail: max whole-token stablecoin the assetManager may have invested at once; owner-set, 0 = no trade limit configured
    uint64 stableCoinInvested; // portfolio: whole-token stablecoin currently deployed into assets; +on stable→asset, -on asset→stable
    uint96 expiredAt; // 0 = not expired
    uint128 lastTradeTimestamp;
    bool fullAccess;
}

// Rolling one-off send quota for the vault's payout operator (stablecoin-normalized 1e18 units in sentInPeriod).
struct PayoutOperatorLimit {
    uint64 interval; // window length in seconds; setPayoutOperator/updatePayoutOperator reject 0 (cap must be enforceable)
    uint64 maxStableCoinPerPeriod; // whole stablecoin tokens per window; setPayoutOperator/updatePayoutOperator reject 0
    uint128 periodStartTimestamp;
    uint256 sentInPeriod;
}

// An asset's default yield route: once the owner sets one, the vault auto-routes the asset's
// spendable wallet balance into the protocol on deposit (the vault's receive() sweeps freshly-wrapped
// ETH into the WETH route), so deposits earn by default. `protocol` is the REGISTERED protocol address
// (not the vault's clone); address(0) = no route configured.
struct AutoYieldConfig {
    address protocol;
    bool isSupplying; // true = lending supply; false = staking stake
}

struct AssetManagerStorage {
    bool isInitialized;

    mapping(address => address) clonedProtocols;
    mapping(address => uint256) minimalBalances;

    // The vault's single asset manager (address(0) = none) and its trade guardrail. Only this address may trade.
    address assetManager;
    AssetManagerSettings assetManagerSettings;

    EnumerableSet.AddressSet lendingProtocols;
    EnumerableSet.AddressSet stakingProtocols;
    EnumerableSet.AddressSet ammProtocols;
    EnumerableSet.AddressSet intentProtocols;

    IBittyV1Guard guard;
    bool addingProtocolsDisabled;
    uint64 rebalanceDisabledUntilTimestamp;

    mapping(bytes32 => IntentOrderRecord) intentOrderRecords;

    mapping(address => uint256) committedIntentSell;

    mapping(address => AutoYieldConfig) autoYieldConfigs;

    address autoYieldTrigger;
}

struct PendingSend {
    address proposer; // address(0) = slot empty
    address[] recipients;
    address[] assets;
    uint256[] amounts;
}

struct VaultStorage {
    bool isInitialized;
    mapping(uint256 => IBittyV1Vault.ScheduledPayment) scheduledPayments;
    mapping(uint256 => uint256) lastReceiveTimestamps;
    // Per-entry protection deadline (unix time): a newly added scheduled payment / whitelisted recipient
    // cannot be paid until block.timestamp reaches this. 0 = no protection (payable immediately). Keyed by
    // the entry's id, so deleting the entry during its window removes the entry entirely.
    mapping(uint256 => uint256) scheduledPaymentEffectiveAt;
    mapping(uint256 => uint256) whitelistedRecipientEffectiveAt;
    IBittyV1Guard guard;
    address weth;
    EnumerableSet.AddressSet assets;
    EnumerableSet.AddressSet stableCoins;
    bool addingAssetsDisabled;

    // Reentrancy lock for native-ETH payouts (the only path that .call's an arbitrary recipient).
    bool payingEth;
    RiskConfig riskConfig;
    // The risk-control preset chosen at activation (recorded for the UI: display + reset-to-default).
    RiskControlLevel riskControlLevel;

    // Registered payout operators and each one's rolling one-off send quota.
    EnumerableSet.AddressSet payoutOperators;
    mapping(address => PayoutOperatorLimit) payoutOperatorLimits;

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
