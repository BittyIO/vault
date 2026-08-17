// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {AccessControlUpgradeable} from "openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";
import {OwnershipNotTransferable} from "./interfaces/IBittyV1Vault.sol";

/**
 * @title BittyV1VaultBase
 * @notice Shared roles + storage layout for {BittyV1Vault} (the core custody/payments contract) and
 *         {BittyV1VaultDeFiFacet} (the asset manager trading/yield contract reached via the vault's fallback).
 *
 *         A vault has exactly ONE, NON-TRANSFERABLE owner (the DEFAULT_ADMIN_ROLE holder). Rather than
 *         OpenZeppelin's AccessControlDefaultAdminRules (which layers a transfer/renounce DELAY we don't
 *         use), this tracks the single owner directly and disables all public role management: no second
 *         admin can be granted, ownership can never be moved, and the role can only be dropped via
 *         {BittyV1Vault-renounceVaultOwnership} — atomic, instant, and rescue-checked. DEFAULT_ADMIN_ROLE is
 *         the vault's only role.
 */
abstract contract BittyV1VaultBase is AccessControlUpgradeable {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;

    AssetManagerStorage internal _assetManager;
    VaultStorage internal _vault;

    address internal _defiFacet;

    // The single vault owner (DEFAULT_ADMIN_ROLE holder); address(0) once renounced.
    address private _vaultOwner;

    /**
     * @notice Public role management is disabled: a vault's one owner is non-transferable and can only
     *         give up the role through {BittyV1Vault-renounceVaultOwnership}. grantRole/revokeRole/renounceRole
     *         all revert, so no second admin can be created and ownership can never be moved.
     */
    function grantRole(bytes32, address) public virtual override {
        revert OwnershipNotTransferable();
    }

    function revokeRole(bytes32, address) public virtual override {
        revert OwnershipNotTransferable();
    }

    function renounceRole(bytes32, address) public virtual override {
        revert OwnershipNotTransferable();
    }

    /**
     * @notice The vault owner (DEFAULT_ADMIN_ROLE holder); address(0) once renounced.
     *         Exposed as both {owner} (IERC5313) and {defaultAdmin} for reader compatibility.
     */
    function owner() public view virtual returns (address) {
        return _vaultOwner;
    }

    function defaultAdmin() public view virtual returns (address) {
        return _vaultOwner;
    }

    /**
     * @dev Set the sole owner at initialization.
     */
    function _initOwner(address owner_) internal {
        _vaultOwner = owner_;
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
    }

    /**
     * @dev Drop ownership: clears the tracked owner and revokes the role (used by renounceVaultOwnership).
     */
    function _renounceOwner() internal {
        address current = _vaultOwner;
        _vaultOwner = address(0);
        _revokeRole(DEFAULT_ADMIN_ROLE, current);
    }
}
