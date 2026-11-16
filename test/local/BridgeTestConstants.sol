// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {PROTOCOL_MARKET_TRADE} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {BITTY_GUARD, MIN_RISK_TIMELOCK, ASSET_BRIDGEABLE, PROTOCOL_BRIDGE} from "../../src/logic/Constants.sol";

uint8 constant PROTOCOL_MARKET_TRADE_ID = PROTOCOL_MARKET_TRADE;
