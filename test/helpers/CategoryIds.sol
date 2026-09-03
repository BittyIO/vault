// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    PROTOCOL_LENDING,
    PROTOCOL_STAKING,
    PROTOCOL_AMM,
    PROTOCOL_INTENT
} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";

// The protocol categories, for tests that talk to the guard.
//
// All four now come from the guard, which is the contract that assigns and answers them. Lending and
// staking used to be bare numbers here because the vault no longer knows either kind exists - it
// deposits into anything depositable - but "the vault does not read it" was never a reason to write
// the value down a second time, and the copy could drift from what the guard actually stores.
uint8 constant LENDING_ID = PROTOCOL_LENDING;
uint8 constant STAKING_ID = PROTOCOL_STAKING;
uint8 constant AMM_ID = PROTOCOL_AMM;
uint8 constant INTENT_ID = PROTOCOL_INTENT;
