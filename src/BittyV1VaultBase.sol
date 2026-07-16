// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AccessControlDefaultAdminRulesUpgradeable
} from "openzeppelin-contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";

/**
 * @title BittyV1VaultBase
 * @notice Shared roles + storage layout for {BittyV1Vault} (the core custody/payments contract) and
 *         {BittyV1VaultDeFiFacet} (the asset-management contract reached via the vault's fallback).
 * @dev CRITICAL: this base declares the storage SHARED between the vault and the facet, which the
 *      facet reads/writes by delegatecall in the vault's storage context — so these slots must be
 *      byte-for-byte identical across both. That holds because this base is their only common
 *      contributor of sequential storage (OZ's AccessControl uses ERC-7201 namespaced storage,
 *      occupying no sequential slots), and inheriting the identical AccessControl base in both also
 *      makes hasRole/onlyRole behave identically across the split.
 *
 *      The facet MUST NOT declare any sequential storage of its own. {BittyV1Vault} may append
 *      core-only storage after this base (e.g. vaultName, _weth): those trailing slots are safe
 *      because the facet never accesses them, but the facet adding its own would collide with them.
 */
abstract contract BittyV1VaultBase is AccessControlDefaultAdminRulesUpgradeable {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;

    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");

    uint48 public constant OWNER_TRANSFER_DELAY = 1 days;

    AssetManagerStorage internal _assetManager;
    VaultStorage internal _vault;

    address internal _defiFacet;
}
