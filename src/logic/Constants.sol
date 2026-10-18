// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

address constant BITTY_GUARD = 0x000000000F5fcD35885BfE4c700042cE7cb39554;

address constant BITTY_FORWARDER = 0xD6013C5e339cd3546c0c7E86c306554a63FbAa6F;

address constant BITTY_FEE_COLLECTOR = 0x5837C8F4963F694C59e53445C070acb266187bF1;

address constant BITTY_VAULT_BOOTSTRAP = 0x06dBcce6A83230B1Ea281F449f960c8F7124cc72;

address constant BITTY_VAULT_FACTORY_BOOTSTRAP = 0x2287De18768eD5eC5F75Ed5d0B7e371809Fa653f;

uint64 constant MAX_RISK_TIMELOCK = 30 days;

/**
 * @dev The floors and ceilings of the risk settings, and the value each takes until the owner sets it.
 *      No setting can be turned off: the timelock is at least a day, and both allowances are at least 1
 *      and at most 10,000 whole USD a day. A vault that has never set one reads the loosest it can be —
 *      the shortest timelock, the largest allowance — so an owner can only tighten from there.
 */
uint64 constant MIN_RISK_TIMELOCK = 1 days;

uint64 constant MAX_SEND_DAILY_ALLOWANCE = 10_000;

uint64 constant MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE = 10_000;

uint64 constant MAX_GRANT_DURATION = 365 days;

uint64 constant SYSTEM_DAILY_MAX_GAS_BUDGET = 100;

uint64 constant SYSTEM_MAX_FEE_PER_OP = 10;

address constant SENTINEL = address(0x1);

uint256 constant SEQUENCER_GRACE_PERIOD = 1 hours; // L2 sequencer grace period

uint256 constant MAX_MARKET_TRADE_SLIPPAGE_BPS = 500; // 5%

uint32 constant PERM_YIELD = 1 << 0;
uint32 constant PERM_SUPPLY = 1 << 1;
uint32 constant PERM_MARKET_TRADE = 1 << 2;
uint32 constant PERM_INTENT = 1 << 3;

