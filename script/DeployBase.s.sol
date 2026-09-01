// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {Deploy} from "./Deploy.s.sol";
import {BITTY_GUARD} from "../src/logic/Constants.sol";

/**
 * @title DeployBase
 * @notice The whole subaccount vault stack on Base: logic libraries, forwarder, shared DeFi facet,
 *         auto-yield keeper, sub-vault implementation, main-vault implementation, factory.
 *
 * @dev {Deploy} is already chain-agnostic — it resolves the chain from the RPC and loads the matching
 *      deployments TOML — so this adds no deployment steps. What it adds is the two preflight checks
 *      that turn the ways a Base run goes wrong into a refusal before anything is broadcast.
 *
 *      The CHAIN check exists because every address here is deterministic: the same salts and the same
 *      init code land on the same addresses on any chain, so a run pointed at the wrong RPC does not
 *      fail — it succeeds, somewhere else, spending real gas and claiming CREATE2 addresses meant for
 *      Base.
 *
 *      The GUARD check exists because the guard is load-bearing at runtime — asset/protocol/impl
 *      registry lookups, and the timelocked implementation allowlist that gates upgrades all read it.
 *      Deploy the guard first so a fresh chain isn't left with a vault stack that can't operate.
 */
contract DeployBase is Deploy {
    uint256 private constant BASE_CHAIN_ID = 8453;

    function deploy() public override {
        require(block.chainid == BASE_CHAIN_ID, "DeployBase: not Base - check --rpc-url");
        require(BITTY_GUARD.code.length > 0, "DeployBase: no guard on this chain - deploy it first");
        super.deploy();
    }
}
