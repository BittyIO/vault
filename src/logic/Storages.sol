// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1Vault} from "../interfaces/IBittyV1Vault.sol";

struct IntentOrderRecord {
    address sellToken; // address(0) = no record
    uint256 expiresAt;
}

struct AssetManagerStorage {
    bool isInitialized;
    address weth;

    mapping(address => address) clonedProtocols;
    mapping(address => uint256) minimalBalances;

    EnumerableSet.AddressSet lendingProtocols;
    EnumerableSet.AddressSet stakingProtocols;
    EnumerableSet.AddressSet ammProtocols;
    EnumerableSet.AddressSet intentProtocols;

    IBittyV1Guard guard;

    bool addingProtocolsDisabled;

    uint256 rebalanceDisabledUntilTimestamp;

    mapping(bytes32 => IntentOrderRecord) intentOrderRecords;
    mapping(address => bytes32) activeTwapPerToken;
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
}
