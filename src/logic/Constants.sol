// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

address constant BITTY_GUARD = 0x9FFd004eDd0eBE0F5B0000c0002e0200001d8D00;

address constant BITTY_FORWARDER = 0x000000009e22008077E3c8d2ef7C717Ccc218b19;

address constant BITTY_FEE_COLLECTOR = 0x76dC42C2E0ef4FB02600430CB0d3A68d015C30AA;

uint64 constant MAX_DURATION = 10 * 365 days;

uint256 constant TRADE_DISABLE_MAX_DURATION = 4 * 365 days;

uint64 constant SYSTEM_DAILY_MAX_GAS_BUDGET = 100;

uint64 constant SYSTEM_MAX_FEE_PER_OP = 10;

address constant SENTINEL = address(0x1);

