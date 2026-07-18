// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1Vault} from "../interfaces/IBittyV1Vault.sol";

struct IntentOrderRecord {
    address sellToken; // address(0) = no record
    uint96 expiresAt; // packs with sellToken into one slot; timestamp fits easily
    // Amount of sellToken this open order reserves; released from committedIntentSell on cancel/expiry.
    uint256 reservedSell;
}

struct TradeLimit {
    uint64 interval; // 0 = no limit
    uint64 maxStableCoinPerTrade; // 0 = no cap
    uint64 maxStableCoinInvestedTotal; // remaining whole-token budget: reduced on stable→asset, increased on asset→stable (0 = no cap)
    uint96 expiredAt; // 0 = not expired
    uint128 lastTradeTimestamp;
}

struct AssetManagerStorage {
    bool isInitialized;

    mapping(address => address) clonedProtocols;
    mapping(address => uint256) minimalBalances;

    mapping(address => TradeLimit) tradeLimits;

    EnumerableSet.AddressSet lendingProtocols;
    EnumerableSet.AddressSet stakingProtocols;
    EnumerableSet.AddressSet ammProtocols;
    EnumerableSet.AddressSet intentProtocols;

    IBittyV1Guard guard;
    bool addingProtocolsDisabled;
    uint64 rebalanceDisabledUntilTimestamp;
    bool ownerAssetManagerDisabled;

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
    bool sendingDisabled;
    // Reentrancy lock for native-ETH payouts (the only path that .call's an arbitrary recipient).
    bool payingEth;
    uint256 newAddressProtection;

    mapping(uint256 => IBittyV1Vault.WhitelistedRecipient) whitelistedRecipients;

    mapping(uint256 => address) scheduledPaymentPendingProposer;
    mapping(uint256 => address) whitelistedRecipientPendingProposer;

    mapping(uint256 => PendingSend) pendingSends;
    uint256 nextPendingSendId;

    uint256 nextScheduledPaymentId;
    uint256 nextWhitelistedRecipientId;
}
