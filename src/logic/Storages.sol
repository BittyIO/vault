// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1Vault} from "../interfaces/IBittyV1Vault.sol";

struct IntentOrderRecord {
    address sellToken; // address(0) = no record
    uint96 expiresAt; // packs with sellToken into one slot; timestamp fits easily
}

// Per-asset-manager trade guardrail (owner-set). Packed into a single 256-bit slot so the whole
// config is one SLOAD and the per-trade lastTradeTimestamp write is a warm SSTORE to that slot.
struct TradeLimit {
    uint64 interval; // min seconds between trades (0 = no throttle)
    uint64 maxStableCoinSize; // max stablecoin per trade in whole tokens, no decimals (0 = no cap)
    uint128 lastTradeTimestamp; // written every trade
}

struct AssetManagerStorage {
    bool isInitialized;

    mapping(address => address) clonedProtocols;
    mapping(address => uint256) minimalBalances;

    // Per-asset-manager trade guardrails (owner-set), keyed by asset-manager address: throttle
    // frequency and cap the stablecoin size of each rebalance so an automated/AI asset manager can
    // only move so much, so often. A size cap requires the trade to have a stablecoin leg.
    mapping(address => TradeLimit) tradeLimits;

    EnumerableSet.AddressSet lendingProtocols;
    EnumerableSet.AddressSet stakingProtocols;
    EnumerableSet.AddressSet ammProtocols;
    EnumerableSet.AddressSet intentProtocols;

    // guard + the bool + the timestamp pack into one slot (160 + 8 + 64 bits); the timestamp is read
    // on every rebalance and now shares guard's already-warm slot.
    IBittyV1Guard guard;
    bool addingProtocolsDisabled;
    uint64 rebalanceDisabledUntilTimestamp;

    mapping(bytes32 => IntentOrderRecord) intentOrderRecords;
}

// Per-micro-payer guardrail (owner-set), keyed by the MICRO_PAYMENT_ROLE holder's address. Packed
// into a single 256-bit slot so the whole config is one SLOAD and the per-payment lastTimestamp write
// is a warm SSTORE to that slot. A payer with no configured cap (maxWholeTokens == 0) cannot pay.
struct MicroPaymentLimit {
    uint64 maxWholeTokens; // max stablecoin per payment in whole tokens, no decimals (0 = payer disabled)
    uint64 interval; // min seconds between this payer's micro-payments
    uint128 lastTimestamp; // written on every payment by this payer
}

struct VaultStorage {
    bool isInitialized;
    mapping(string => IBittyV1Vault.ScheduledPayment) scheduledPayments;
    mapping(string => uint256) lastReceiveTimestamps;
    // Protection deadline keyed by payee ADDRESS (not name) and SHARED by scheduled payments and
    // whitelisted recipients: once an address is time-locked it stays locked everywhere until the
    // window elapses or the address is removed, so a protected address cannot be laundered through
    // the other feature to pay it early.
    mapping(address => uint256) newAddressProtectionTimestamps;
    IBittyV1Guard guard;
    EnumerableSet.AddressSet assets;
    EnumerableSet.AddressSet stableCoins;
    bool addingAssetsDisabled;
    // Time-lock window (seconds) applied to every newly added scheduled payment AND newly added
    // whitelisted recipient: the address cannot be paid until the window elapses, giving the owner
    // time to notice and remove a malicious/mistaken entry.
    uint256 newAddressProtection;

    // Owner discretionary micro-payment of stablecoin to arbitrary addresses, rate-limited PER
    // micro-payer: each MICRO_PAYMENT_ROLE holder has its own cap, interval and clock, keyed by the
    // payer's address, so a compromised payer key can only drain within that one payer's budget and
    // only the payer the owner configured can spend.
    mapping(address => MicroPaymentLimit) microPaymentLimits;

    // Owner-curated payees the owner can pay any amount on demand, keyed by name.
    mapping(string => IBittyV1Vault.WhitelistedRecipient) whitelistedRecipients;
}
