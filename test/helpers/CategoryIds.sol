// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {AMM_CATEGORY, INTENT_CATEGORY} from "../../src/logic/Constants.sol";

// The protocol categories, for tests that talk to the guard.
//
// AMM and intent come from Constants because the vault itself reads them: it has to know an AMM from
// an intent relayer to route addLiquidity and to check an order signature.
//
// Lending and staking are declared here instead, as bare numbers, because the vault no longer knows
// either one exists. It deposits into anything depositable and exits anything withdrawable, so these
// two ids now only describe a protocol for whoever reads the guard - the catalog in the web app -
// and mean nothing to the contracts under test.
uint8 constant LENDING_ID = 1;
uint8 constant STAKING_ID = 2;
uint8 constant AMM_ID = AMM_CATEGORY;
uint8 constant INTENT_ID = INTENT_CATEGORY;
