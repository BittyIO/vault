// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

address constant BITTY_GUARD = 0x00000000Bc92Dc726B7D9b260bC946bf27Bfa838;

address constant BITTY_FORWARDER = 0x00001200549c790d1A6156FA00002Eab1d0400e0;

address constant BITTY_FEE_COLLECTOR = 0x76dC42C2E0ef4FB02600430CB0d3A68d015C30AA;

uint64 constant MAX_DURATION = 10 * 365 days;

uint256 constant TRADE_DISABLE_MAX_DURATION = 4 * 365 days;

uint64 constant SYSTEM_DAILY_MAX_GAS_BUDGET = 100;

uint64 constant SYSTEM_MAX_FEE_PER_OP = 10;

address constant SENTINEL = address(0x1);

uint8 constant STABLE_COIN_CATEGORY = 1;

uint8 constant AMM_CATEGORY = 3;

uint8 constant INTENT_CATEGORY = 4;
