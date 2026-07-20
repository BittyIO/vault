// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1Vault, RiskControlLevel} from "../interfaces/IBittyV1Vault.sol";

struct IntentOrderRecord {
    address sellToken; // address(0) = no record
    uint96 expiresAt; // packs with sellToken into one slot; timestamp fits easily
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

// Payment risk controls (payments only; trading limits live in TradeLimit). Not tighten-only: the
// owner may set any value, but loosening is delayed by `changeTimelock` (see TimelockedValue).
struct RiskConfig {
    // Time-lock (seconds) applied to a newly added payee before its first payout; higher = safer.
    TimelockedValue newAddressProtection;
    // Per-payment caps in stablecoin whole tokens; 0 = unrestricted (any asset, no cap). A non-zero cap
    // makes that path stablecoin-only AND requires amount <= cap * 10**decimals. Lower (non-zero) = safer.
    TimelockedValue maxSendValue; // one-off sends
    TimelockedValue maxScheduledValue; // scheduled payments (checked when added)
    TimelockedValue maxWhitelistedValue; // whitelisted-recipient payouts (checked at payout)
    // Delay (seconds) a loosening of any of the above (or of this value) must wait; 0 = changes instant.
    TimelockedValue changeTimelock;
}

struct TradeLimit {
    uint64 interval; // 0 = no limit
    uint64 maxStableCoinPerTrade; // 0 = no cap
    uint64 stableCoinInvestCap; // guardrail: max whole-token stablecoin the manager may have invested at once; owner-set, 0 = no trade limit configured
    uint64 stableCoinInvested; // portfolio: whole-token stablecoin currently deployed into assets; +on stable→asset, -on asset→stable
    uint96 expiredAt; // 0 = not expired
    uint128 lastTradeTimestamp;
    // true = a full-access manager: bounded only by minimalBalance, skips the cap/throttle accounting
    // (and the stablecoin-leg requirement). Packs into the trailing slot with expiredAt/lastTradeTimestamp.
    bool fullAccess;
}

struct AssetManagerStorage {
    bool isInitialized;

    mapping(address => address) clonedProtocols;
    mapping(address => uint256) minimalBalances;

    // The vault's single asset manager (address(0) = none) and its trade guardrail. Only this address
    // may trade; the owner sets it and may make itself the manager.
    address assetManager;
    TradeLimit assetManagerLimit;

    EnumerableSet.AddressSet lendingProtocols;
    EnumerableSet.AddressSet stakingProtocols;
    EnumerableSet.AddressSet ammProtocols;
    EnumerableSet.AddressSet intentProtocols;

    IBittyV1Guard guard;
    bool addingProtocolsDisabled;
    uint64 rebalanceDisabledUntilTimestamp;

    mapping(bytes32 => IntentOrderRecord) intentOrderRecords;

    mapping(address => uint256) committedIntentSell;
}

struct PendingSend {
    address proposer; // address(0) = slot empty
    address recipient;
    address asset;
    uint256 amount;
}

struct VaultStorage {
    bool isInitialized;
    mapping(uint256 => IBittyV1Vault.ScheduledPayment) scheduledPayments;
    mapping(uint256 => uint256) lastReceiveTimestamps;
    mapping(address => uint256) newAddressProtectionTimestamps;
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

    mapping(uint256 => IBittyV1Vault.WhitelistedRecipient) whitelistedRecipients;

    mapping(uint256 => address) scheduledPaymentPendingProposer;
    mapping(uint256 => address) whitelistedRecipientPendingProposer;

    mapping(uint256 => PendingSend) pendingSends;
    uint256 nextPendingSendId;

    uint256 nextScheduledPaymentId;
    uint256 nextWhitelistedRecipientId;
}
