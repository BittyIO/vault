// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IAssetManager} from "../interfaces/IAssetManager.sol";
import {IRegistry} from "registry-contracts/src/interfaces/IRegistry.sol";
import {IVault} from "../interfaces/IVault.sol";

struct AssetManagerStorage {
    bool isInitialized;
    address weth;

    mapping(address => address) clonedProtocols;
    mapping(address => IAssetManager.RebalanceConfig) rebalanceConfigs;
    mapping(address => uint256) lastRebalanceTimestamps;

    EnumerableSet.AddressSet lendingProtocols;
    EnumerableSet.AddressSet stakingProtocols;
    EnumerableSet.AddressSet ammProtocols;

    IRegistry registry;

    bool addingProtocolsDisabled;

    uint256 rebalanceDisabledUntilTimestamp;
}

struct VaultStorage {
    bool isInitialized;
    mapping(string => IVault.Receiver) receivers;
    mapping(string => uint256) lastReceiveTimestamps;
    mapping(string => uint256) newReceiverProtectionTimestamps;
    IRegistry registry;
    EnumerableSet.AddressSet assets;
    EnumerableSet.AddressSet stableCoins;
    bool addingAssetsDisabled;
    uint256 newReceiverProtection;
}
