// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    PROTOCOL_LENDING,
    PROTOCOL_STAKING,
    PROTOCOL_INTENT
} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {PROTOCOL_MARKET_TRADE} from "../../src/logic/Constants.sol";

uint8 constant LENDING_ID = PROTOCOL_LENDING;
uint8 constant STAKING_ID = PROTOCOL_STAKING;
uint8 constant MARKET_TRADE_ID = PROTOCOL_MARKET_TRADE;
// Market makers carry no category of their own — they register under the shared AMM slot and are told
// apart from swap adapters by the interface the vault calls, not by a category number.
uint8 constant MARKET_MAKER_ID = PROTOCOL_MARKET_TRADE;
uint8 constant AMM_ID = PROTOCOL_MARKET_TRADE;
uint8 constant INTENT_ID = PROTOCOL_INTENT;
