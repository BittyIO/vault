// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    PROTOCOL_LENDING,
    PROTOCOL_STAKING,
    PROTOCOL_MARKET_TRADE,
    PROTOCOL_MARKET_MAKER,
    PROTOCOL_INTENT
} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";

uint8 constant LENDING_ID = PROTOCOL_LENDING;
uint8 constant STAKING_ID = PROTOCOL_STAKING;
uint8 constant MARKET_TRADE_ID = PROTOCOL_MARKET_TRADE;
// Market makers carry a category of their own now, so a swap adapter and a liquidity adapter are told
// apart by what the guard recorded rather than by the interface the vault happens to call.
uint8 constant MARKET_MAKER_ID = PROTOCOL_MARKET_MAKER;
uint8 constant INTENT_ID = PROTOCOL_INTENT;
