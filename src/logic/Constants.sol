// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

address constant BITTY_GUARD = 0x000000000F5fcD35885BfE4c700042cE7cb39554;

address constant BITTY_FORWARDER = 0xD6013C5e339cd3546c0c7E86c306554a63FbAa6F;

address constant BITTY_FEE_COLLECTOR = 0x76dC42C2E0ef4FB02600430CB0d3A68d015C30AA;

address constant BITTY_VAULT_BOOTSTRAP = 0x06dBcce6A83230B1Ea281F449f960c8F7124cc72;

address constant BITTY_VAULT_FACTORY_BOOTSTRAP = 0x2287De18768eD5eC5F75Ed5d0B7e371809Fa653f;

uint64 constant MAX_RISK_TIMELOCK = 30 days;

uint64 constant MAX_GRANT_DURATION = 10 * 365 days;

uint64 constant SYSTEM_DAILY_MAX_GAS_BUDGET = 100;

uint64 constant SYSTEM_MAX_FEE_PER_OP = 10;

address constant SENTINEL = address(0x1);

bytes32 constant CFG_GAS_WRAPPED = keccak256("bitty.gasWrapped");

bytes32 constant CFG_OWNER = keccak256("bitty.owner");

uint32 constant PERM_YIELD = 1 << 0;
uint32 constant PERM_SUPPLY = 1 << 1;
uint32 constant PERM_MARKET_TRADE = 1 << 2;
uint32 constant PERM_MARKET_MAKER = 1 << 3;
uint32 constant PERM_INTENT = 1 << 4;

