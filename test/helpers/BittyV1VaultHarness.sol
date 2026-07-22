// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "openzeppelin-contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

abstract contract BittyV1VaultHarness is BittyV1Vault, BittyV1VaultDeFiFacet {}
