// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IAssetManager} from "../interfaces/IAssetManager.sol";
import {IWhiteList} from "whitelist-contracts/src/interfaces/IWhiteList.sol";
import {IVault} from "../interfaces/IVault.sol";

struct AssetManagerStorage {
    bool isInitialized;
    address assetManager;

    mapping(address => address) clonedProviders;
    mapping(address => IAssetManager.AssetConfig) assetConfigs;
    mapping(address => uint256) lastRebalanceTimestamps;

    EnumerableSet.AddressSet assetConfigKeys;
    EnumerableSet.AddressSet lastRebalanceTimestampKeys;

    EnumerableSet.AddressSet lendingProviders;
    EnumerableSet.AddressSet stakingProviders;
    EnumerableSet.AddressSet swapProviders;
    EnumerableSet.AddressSet intentProviders;

    IWhiteList whiteList;

    uint256 rebalanceDisabledUntilTimestamp;
}

struct VaultStorage {
    bool isInitialized;
    mapping(string => IVault.Receiver) receivers;
    address weth;
    IWhiteList whiteList;
    EnumerableSet.AddressSet assets;
    EnumerableSet.AddressSet stableCoins;
    bool addingAssetsDisabled;
}
