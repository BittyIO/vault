// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AccessControlDefaultAdminRulesUpgradeable
} from "openzeppelin-contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {ManagerLogic} from "./logic/ManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {ManagerStorage, VaultStorage} from "./logic/Storages.sol";

/**
 * @title BittyV1VaultBase
 * @notice Shared roles + storage layout for {BittyV1Vault} (the core custody/payments contract) and
 *         {BittyV1VaultDeFiFacet} (the manager trading/yield contract reached via the vault's fallback).
 */
abstract contract BittyV1VaultBase is AccessControlDefaultAdminRulesUpgradeable {
    using ManagerLogic for ManagerStorage;
    using VaultLogic for VaultStorage;

    uint48 public constant OWNER_TRANSFER_DELAY = 1 days;

    ManagerStorage internal _manager;
    VaultStorage internal _vault;

    address internal _defiFacet;
}
