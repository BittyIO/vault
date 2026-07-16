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

struct PendingSend {
    address proposer; // address(0) = slot empty
    address recipient;
    address asset;
    uint256 amount;
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
    // A payment whose asset is address(0) means "pay in ETH": direct-balance paths unwrap this WETH.
    address weth;
    EnumerableSet.AddressSet assets;
    EnumerableSet.AddressSet stableCoins;
    bool addingAssetsDisabled;
    bool sendingDisabled;
    // Reentrancy lock for native-ETH payouts (the only path that .call's an arbitrary recipient).
    bool payingEth;
    // Time-lock window (seconds) applied to every newly added scheduled payment AND newly added
    // whitelisted recipient: the address cannot be paid until the window elapses, giving the owner
    // time to notice and remove a malicious/mistaken entry.
    uint256 newAddressProtection;

    // Owner-curated payees the owner can pay any amount on demand, keyed by name.
    mapping(string => IBittyV1Vault.WhitelistedRecipient) whitelistedRecipients;

    // Payment-manager approval workflow: a PAYMENT_MANAGER_ROLE holder can create entries, but the
    // owner must approve them before they are payable. address(0) = approved/active (or absent); a
    // non-zero value is the payment manager who proposed it and the entry cannot be paid yet.
    mapping(string => address) scheduledPaymentPendingProposer;
    mapping(string => address) whitelistedRecipientPendingProposer;

    mapping(uint256 => PendingSend) pendingSends;
    uint256 nextPendingSendId;
}
