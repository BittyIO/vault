// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IAssetManager} from "../interfaces/IAssetManager.sol";
import {IWhiteList} from "../interfaces/IWhiteList.sol";

struct AssetManagerStorage {
    bool isInitialized;
    address assetManager;

    mapping(address => address) clonedProviders;
    mapping(address => IAssetManager.AssetConfig) assetConfigs;
    mapping(address => uint256) lastRebalanceTimestamps;

    EnumerableSet.AddressSet assetConfigKeys;
    EnumerableSet.AddressSet lastRebalanceTimestampKeys;

    EnumerableSet.AddressSet yieldProviders;
    EnumerableSet.AddressSet swapProviders;

    IWhiteList whiteList;

    uint256 lastRebalanceTimestamp;
    IAssetManager.RebalanceLimit rebalanceLimit;

    IAssetManager.ManageFee manageFee;
    uint256 lastBaseFeeTime;
    uint256 lastRevenueTime;
    uint256 revenue;
}

struct VaultStorage {
    bool isInitialized;
    address grantor;
    address weth;
    IWhiteList whiteList;
    EnumerableSet.AddressSet assets;
    EnumerableSet.AddressSet stableCoins;
}
