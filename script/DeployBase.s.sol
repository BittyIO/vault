// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {Deploy} from "./Deploy.s.sol";
import {BITTY_GUARD} from "../src/logic/Constants.sol";

/**
 * @title DeployBase
 * @notice The whole vault stack on Base: logic libraries, forwarder, DeFi facet, auto-yield keeper,
 *         implementation, factory.
 *
 * @dev {Deploy} is already chain-agnostic — it resolves the chain from the RPC and loads the matching
 *      deployments TOML — so this adds no deployment steps. What it adds is the two preflight checks
 *      that turn the ways a Base run goes wrong into a refusal before anything is broadcast.
 *
 *      The CHAIN check exists because every address here is deterministic: the same salts and the
 *      same init code land on the same addresses on any chain, so a run pointed at the wrong RPC
 *      does not fail — it succeeds, somewhere else, spending real gas and claiming CREATE2 addresses
 *      that were meant for Base.
 *
 *      The GUARD check exists because a vault's initialize seeds its allow-list from the guard's
 *      registry (see VaultLogic.seedMinimalAllowList), and this script initializes the implementation
 *      to lock it. With no guard deployed that call reverts halfway through the run, after the
 *      libraries, forwarder, facet and keeper are already on chain — recoverable, since the script is
 *      idempotent, but a confusing way to find out. Deploy the guard first.
 */
contract DeployBase is Deploy {
    uint256 private constant BASE_CHAIN_ID = 8453;

    function deploy() public override {
        require(block.chainid == BASE_CHAIN_ID, "DeployBase: not Base - check --rpc-url");
        require(BITTY_GUARD.code.length > 0, "DeployBase: no guard on this chain - deploy it first");
        super.deploy();
    }
}
