// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1Vault} from "../../src/BittyV1Vault.sol";

/**
 * Stands in for the next release.
 *
 * A second instance of the SAME build no longer counts as an upgrade target: a vault may only move
 * FORWARD, so re-pointing at an equal version is refused. That rule is what stops a thief holding
 * the owner key from rolling a vault back onto an older blessed implementation — code that never
 * heard of the locks and hands ownership over on the spot — so every test that needs a real upgrade
 * needs a target that honestly claims a higher version. See {BittyV1VaultBase-_authorizeUpgrade}.
 */
contract NextReleaseVault is BittyV1Vault {
    constructor(address defiFacet) BittyV1Vault(defiFacet) {}

    function vaultVersion() external pure override returns (uint256) {
        return 1 * 1_000_000 + 1 * 1_000 + 0;
    }
}
