// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    PROTOCOL_LENDING,
    PROTOCOL_STAKING,
    PROTOCOL_MARKET_TRADE,
    PROTOCOL_INTENT
} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";

uint8 constant LENDING_ID = PROTOCOL_LENDING;
uint8 constant STAKING_ID = PROTOCOL_STAKING;
uint8 constant MARKET_TRADE_ID = PROTOCOL_MARKET_TRADE;
uint8 constant INTENT_ID = PROTOCOL_INTENT;
