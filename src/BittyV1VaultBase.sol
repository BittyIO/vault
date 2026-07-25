// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AccessControlDefaultAdminRulesUpgradeable
} from "openzeppelin-contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";
import {OwnershipNotTransferable, DefaultAdminDelayImmutable} from "./interfaces/IBittyV1Vault.sol";

/**
 * @title BittyV1VaultBase
 * @notice Shared roles + storage layout for {BittyV1Vault} (the core custody/payments contract) and
 *         {BittyV1VaultDeFiFacet} (the asset manager trading/yield contract reached via the vault's fallback).
 */
abstract contract BittyV1VaultBase is AccessControlDefaultAdminRulesUpgradeable {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;

    uint48 public constant OWNER_TRANSFER_DELAY = 1 days;

    AssetManagerStorage internal _assetManager;
    VaultStorage internal _vault;

    address internal _defiFacet;

    /**
     * @notice Vault ownership is not transferable. The admin role can still be renounced (a transfer
     *         begun toward `address(0)` followed by {renounceRole} after the delay), leaving the vault
     *         ownerless, but it can never be moved to another account. Before renouncing, the owner
     *         should set up an immutable scheduled payment and let its lock window pass (making it
     *         permanent — it survives both a key compromise and the renounce), and remove every other
     *         entry: an ownerless vault can pay out only through its scheduled payments.
     */
    function beginDefaultAdminTransfer(address newAdmin) public virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin != address(0)) revert OwnershipNotTransferable();
        super.beginDefaultAdminTransfer(newAdmin);
    }

    /**
     * @notice The 1-day admin delay doubles as the guaranteed renounce review window, so it can never
     *         be changed — a compromised owner key must not be able to shorten it.
     */
    function changeDefaultAdminDelay(uint48) public virtual override {
        revert DefaultAdminDelayImmutable();
    }

    function rollbackDefaultAdminDelay() public virtual override {
        revert DefaultAdminDelayImmutable();
    }
}
