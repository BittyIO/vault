// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "openzeppelin-contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

/**
 * @dev Test-only monolith exposing both the core vault and DeFi-facet surfaces as directly-typed
 *      members, for white-box tests that inherit the vault and call functions on `this`. In
 *      production the two are deployed separately and the core forwards asset-management selectors to
 *      the facet via its fallback; here they're combined so `this.marketSell(...)` etc. type-check.
 */
// Marked `abstract` because this test-only monolith is never deployed on its own — the two
// production contracts are deployed separately and it is only ever inherited by test contracts.
// Being abstract also keeps it out of the `forge build --sizes` deploy-size gate, which it would
// otherwise trip by design (it combines the full surface of both production contracts).
abstract contract BittyV1VaultHarness is BittyV1Vault, BittyV1VaultDeFiFacet {
    // Disambiguate the _grantRole overridden by BittyV1Vault (owner/manager exclusion) and inherited
    // via the facet from AccessControlDefaultAdminRulesUpgradeable. super routes to BittyV1Vault's,
    // preserving the invariant.
    function _grantRole(bytes32 role, address account)
        internal
        override(BittyV1Vault, AccessControlDefaultAdminRulesUpgradeable)
        returns (bool)
    {
        return super._grantRole(role, account);
    }

    // Disambiguate the public grantRole (BittyV1Vault blocks ASSET_MANAGER_ROLE) inherited via both
    // parents. super routes to BittyV1Vault's, preserving the block.
    function grantRole(bytes32 role, address account)
        public
        override(BittyV1Vault, AccessControlDefaultAdminRulesUpgradeable)
    {
        super.grantRole(role, account);
    }

    // Disambiguate the public revokeRole (BittyV1Vault blocks ASSET_MANAGER_ROLE) inherited via both
    // parents. super routes to BittyV1Vault's, preserving the block.
    function revokeRole(bytes32 role, address account)
        public
        override(BittyV1Vault, AccessControlDefaultAdminRulesUpgradeable)
    {
        super.revokeRole(role, account);
    }

    // Disambiguate the beginDefaultAdminTransfer overridden by BittyV1Vault (rejects payment-manager
    // targets) inherited via both parents. super routes to BittyV1Vault's, preserving the check.
    function beginDefaultAdminTransfer(address newAdmin)
        public
        override(BittyV1Vault, AccessControlDefaultAdminRulesUpgradeable)
    {
        super.beginDefaultAdminTransfer(newAdmin);
    }
}
