// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

address constant BITTY_GUARD = 0x000000000F5fcD35885BfE4c700042cE7cb39554;

address constant BITTY_FORWARDER = 0xD6013C5e339cd3546c0c7E86c306554a63FbAa6F;

// Vault owned by the Safe (0x5837C8F4963F694C59e53445C070acb266187bF1)
address constant BITTY_FEE_COLLECTOR = 0xF0E7f6998B362BD15CF819C7EBfcaCe8865FECA0;

address constant BITTY_VAULT_BOOTSTRAP = 0x06dBcce6A83230B1Ea281F449f960c8F7124cc72;

address constant BITTY_VAULT_FACTORY_BOOTSTRAP = 0x2287De18768eD5eC5F75Ed5d0B7e371809Fa653f;

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

uint256 constant SEQUENCER_GRACE_PERIOD = 1 hours; // L2 sequencer grace period

uint256 constant MAX_MARKET_TRADE_SLIPPAGE_BPS = 500; // 5%

uint32 constant PERM_YIELD = 1 << 0;
uint32 constant PERM_SUPPLY = 1 << 1;
uint32 constant PERM_MARKET_TRADE = 1 << 2;
uint32 constant PERM_INTENT = 1 << 3;

uint8 constant ASSET_BRIDGEABLE = 8;
uint8 constant PROTOCOL_BRIDGE = 5;

// A whitelisted recipient's chain meaning every EVM chain: the same address here and on any chain a
// bridge route in the guard reaches. See {IBittyV1DeFi-addWhitelistedRecipientOn}.
uint256 constant ANY_EVM_CHAIN = type(uint256).max;

// The guard config key that marks `chainId` as an EVM chain (value 1), where an {ANY_EVM_CHAIN}
// recipient's address is the same holder's: keccak256(abi.encode(EVM_CHAIN_KEY, chainId)). A
// chain the guard has not marked is not one, so a new EVM chain needs only the guard's word, and
// TRON or Solana, never marked, are never sent an EVM recipient's money.
bytes32 constant EVM_CHAIN_KEY = keccak256("bitty.chain.evm");
