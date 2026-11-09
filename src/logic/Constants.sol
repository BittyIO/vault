// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

address constant BITTY_GUARD = 0xb609AAAEbB9775Ea3037C4D3dde427498c457AD1;

address constant BITTY_FORWARDER = 0xC9c6F29869FFFbe8847b8519Fee52481E17Ba85b;

// Vault owned by the Safe (0x5837C8F4963F694C59e53445C070acb266187bF1)
address constant BITTY_FEE_COLLECTOR = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

address constant BITTY_VAULT_BOOTSTRAP = 0x584C1CB9995fF8ADF0eE1B82BF25Db7Be7c33fA8;

address constant BITTY_VAULT_FACTORY_BOOTSTRAP = 0x1b2a7EB846eE13623aFC078EEFc76BC2698CF341;

uint64 constant MAX_RISK_TIMELOCK = 30 days;

uint64 constant MIN_RISK_TIMELOCK = 1 days;

uint64 constant MAX_SEND_DAILY_ALLOWANCE = 10_000;

uint64 constant MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE = 10_000;

// What a new vault starts with: a starting value, not a floor — the owner may lower it at once, to 0.
uint64 constant DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE = 1_000;

// How an allowance of 0 is stored: a stored 0 already means "never set", which reads as the maximum.
uint64 constant ALLOWANCE_ZERO = type(uint64).max;

uint64 constant MAX_GRANT_DURATION = 365 days;

uint64 constant SYSTEM_DAILY_MAX_GAS_BUDGET = 100;

uint64 constant SYSTEM_MAX_FEE_PER_OP = 10;

address constant SENTINEL = address(0x1);

// TRON: what CHAINID / block.chainid returns on each network (the low 4 bytes of the genesis block hash).
uint256 constant TRON_MAINNET_CHAIN_ID = 728126428; // 0x2b6653dc
uint256 constant TRON_NILE_CHAIN_ID = 3448148188; // 0xcd8690dc

// TRON: the native coin is TRX, counted in sun (6 decimals), not wei.
uint8 constant NATIVE_DECIMALS = 6;

uint256 constant SEQUENCER_GRACE_PERIOD = 1 hours; // L2 sequencer grace period

uint256 constant MAX_MARKET_TRADE_SLIPPAGE_BPS = 500; // 5%

uint32 constant PERM_YIELD = 1 << 0;
uint32 constant PERM_SUPPLY = 1 << 1;
uint32 constant PERM_MARKET_TRADE = 1 << 2;
uint32 constant PERM_INTENT = 1 << 3;

