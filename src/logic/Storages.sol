// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IAssetManager} from "../interfaces/IAssetManager.sol";
import {IGuard} from "guard-contracts/src/interfaces/IGuard.sol";
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

    IGuard guard;

    bool addingProtocolsDisabled;

    uint256 rebalanceDisabledUntilTimestamp;
}

struct VaultStorage {
    bool isInitialized;
    mapping(string => IVault.Receiver) receivers;
    mapping(string => uint256) lastReceiveTimestamps;
    mapping(string => uint256) newReceiverProtectionTimestamps;
    IGuard guard;
    EnumerableSet.AddressSet assets;
    EnumerableSet.AddressSet stableCoins;
    bool addingAssetsDisabled;
    uint256 newReceiverProtection;
}
