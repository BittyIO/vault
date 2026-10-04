// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {PROTOCOL_AMM} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";

uint8 constant PROTOCOL_MARKET_TRADE = PROTOCOL_AMM;

address constant BITTY_GUARD = 0x00006Dc0000DBB00d9bd462ad2005E20007e0Dc7;

address constant BITTY_FORWARDER = 0xfB49bE0861AC05bC690327076130342966429c03;

address constant BITTY_FEE_COLLECTOR = 0x76dC42C2E0ef4FB02600430CB0d3A68d015C30AA;

address constant BITTY_VAULT_BOOTSTRAP = 0x06dBcce6A83230B1Ea281F449f960c8F7124cc72;

address constant BITTY_VAULT_FACTORY_BOOTSTRAP = 0xE07Bb6BB6D97382A0922076259CbE2d5c6FBb6D4;

uint64 constant MAX_DURATION = 10 * 365 days;

uint256 constant TRADE_DISABLE_MAX_DURATION = 4 * 365 days;

uint64 constant SYSTEM_DAILY_MAX_GAS_BUDGET = 100;

uint64 constant SYSTEM_MAX_FEE_PER_OP = 10;

address constant SENTINEL = address(0x1);

bytes32 constant CFG_GAS_WRAPPED = keccak256("bitty.gasWrapped");

bytes32 constant CFG_OWNER = keccak256("bitty.owner");

