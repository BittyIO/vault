// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";

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
abstract contract BittyV1VaultHarness is BittyV1Vault, BittyV1VaultDeFiFacet {}
