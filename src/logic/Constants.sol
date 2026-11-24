// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

address constant BITTY_GUARD = 0xf022C72D48c2E3B81731dbA6649BF780302c0035;

address constant BITTY_FORWARDER = 0x9CC67362c259BC25fC4c027ac44Ce5627E9aDA09;

// Vault owned by the Safe (0x5837C8F4963F694C59e53445C070acb266187bF1)
address constant BITTY_FEE_COLLECTOR = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

address constant BITTY_VAULT_BOOTSTRAP = 0x85f018F64dE9e4A780c11beB30674b335ae2939d;

address constant BITTY_VAULT_FACTORY_BOOTSTRAP = 0x382626C090dA4cA15B796EDC5557dC8e1A7Bde31;

uint64 constant MAX_RISK_TIMELOCK = 30 days;

// The shortest timelock above 0, and what an unset one reads as on a vault created before 1.1.1.
uint64 constant MIN_RISK_TIMELOCK = 1 days;

uint64 constant MAX_DAILY_ALLOWANCE = 1_000_000;

// What an unset allowance reads as on a vault created before 1.0.10.
uint64 constant LEGACY_DAILY_ALLOWANCE = 10_000;

// What a new vault starts with: a starting value, not a floor — the owner may lower it at once, to 0.
uint64 constant DEFAULT_DAILY_LOSS_ALLOWANCE = 1_000;

// How a timelock or an allowance of 0 is stored: a stored 0 already means "never set".
uint64 constant STORED_ZERO = type(uint64).max;

// An allowance of no limit: sends of any asset and amount, trades unpriced. Above every cap, so moving to it loosens.
uint64 constant NO_LIMIT = type(uint64).max - 1;

uint64 constant MAX_GRANT_DURATION = 365 days;

uint64 constant SYSTEM_DAILY_MAX_GAS_BUDGET = 100;

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

uint8 constant ASSET_BRIDGEABLE = 8;
uint8 constant PROTOCOL_BRIDGE = 5;

