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
    address weth;

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

struct VaultStorage {
    bool isInitialized;
    mapping(string => IBittyV1Vault.Receiver) receivers;
    mapping(string => uint256) lastReceiveTimestamps;
    mapping(string => uint256) newReceiverProtectionTimestamps;
    IBittyV1Guard guard;
    EnumerableSet.AddressSet assets;
    EnumerableSet.AddressSet stableCoins;
    bool addingAssetsDisabled;
    uint256 newReceiverProtection;

    // Owner discretionary quick-pay of stablecoin to arbitrary addresses, rate-limited by
    // a per-payment cap (in whole tokens) and a single shared minimum interval. Packed into one
    // slot: the cap+interval are set rarely, lastQuickPayTimestamp is the per-payment write.
    uint64 quickPayMaxWholeTokens;
    uint64 quickPayInterval;
    uint128 lastQuickPayTimestamp;
}
