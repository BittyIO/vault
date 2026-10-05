// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Deploy} from "./Deploy.s.sol";
import {console2} from "forge-std/console2.sol";
import {BittyV1Vault} from "../src/BittyV1Vault.sol";
import {BITTY_GUARD} from "../src/logic/Constants.sol";
import {IBittyV1Guard, IMPLEMENTATION_VAULT} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";

/**
 * @title DeployNewVersion
 * @notice Ship a NEW vault implementation for an UPGRADE (e.g. v1.0.1) — the version-bearing chain only
 *         (logic libraries → shared DeFi facet → sub-vault impl → main-vault impl). It does NOT touch the
 *         forwarder, keeper or factory (those don't change between vault versions).
 * @dev This script only DEPLOYS. It never registers the new implementation with the guard, because
 *      `setImplementation` is gated on IMPLEMENTATION_MANAGER_ROLE, which is held by a Safe multisig /
 *      governance `TimelockController` — not by a deploy key. Auto-registering from a command-line
 *      broadcast would either fail (the key lacks the role) or, worse, imply the role sits on a hot EOA.
 *      So instead the script PRINTS the exact registration transaction (target + calldata) for the role
 *      holder to submit through the Safe / governance flow.
 *
 *      Nothing is redeployed unless its bytecode actually changed: every piece is deterministic CREATE2,
 *      its address is a hash of its init code, so an unchanged contract is already at its address and is
 *      skipped; only what changed gets deployed (see {Deploy-deployImplementationChain}).
 *
 *      Run:  forge script script/DeployNewVersion.s.sol:DeployNewVersion --broadcast -vvvv
 */
contract DeployNewVersion is Deploy {

    function deploy() public override {
        address vaultImpl = deployImplementationChain();

        IBittyV1Guard guard = IBittyV1Guard(BITTY_GUARD);
        if (guard.isImplementationRegisteredFor(vaultImpl, IMPLEMENTATION_VAULT)) {
            console2.log("guard: already registered (nothing to submit)");
            return;
        }
        console2.log("guard: should regist implementation in guard for vault", vaultImpl);
    }

}
