// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {PROTOCOL_AMM} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";

uint8 constant PROTOCOL_MARKET_TRADE = PROTOCOL_AMM;

address constant BITTY_GUARD = 0x00006Dc0000DBB00d9bd462ad2005E20007e0Dc7;

address constant BITTY_FORWARDER = 0xfB49bE0861AC05bC690327076130342966429c03;

address constant BITTY_FEE_COLLECTOR = 0x76dC42C2E0ef4FB02600430CB0d3A68d015C30AA;

address constant BITTY_VAULT_BOOTSTRAP = 0x06dBcce6A83230B1Ea281F449f960c8F7124cc72;

address constant BITTY_VAULT_FACTORY_BOOTSTRAP = 0xE07Bb6BB6D97382A0922076259CbE2d5c6FBb6D4;

uint64 constant MAX_DURATION = 10 * 365 days;

uint64 constant SYSTEM_DAILY_MAX_GAS_BUDGET = 100;

uint64 constant SYSTEM_MAX_FEE_PER_OP = 10;

address constant SENTINEL = address(0x1);

bytes32 constant CFG_GAS_WRAPPED = keccak256("bitty.gasWrapped");

bytes32 constant CFG_OWNER = keccak256("bitty.owner");

/*
 * What an asset manager is allowed to DO, as a bit set the owner passes when appointing one.
 *
 * The grant used to be all-or-nothing: a key appointed to put idle dollars into Sky could also sell
 * the whole balance at market, which is the one thing it is not trusted with — a market order's
 * price is whatever its caller passes, so a route through pools the manager provides moves the
 * vault's value somewhere it controls. The owner now says which job they are handing over.
 *
 * ALWAYS EXPLICIT. There is no "everything" and no default: {setAssetManager} takes the mask, and a
 * mask of zero appoints a key that can do nothing — which is also what a grant made before these
 * bits existed reads as, so such a manager is inert until the owner re-appoints it saying what for.
 * Nothing here is a convenience for the caller; a union of every bit belongs in the client that
 * draws the checkboxes, not in the vault, and an undefined bit authorises nothing because every
 * check below asks for one bit by name.
 *
 * {PERM_INTENT} is one bit for limit AND TWAP orders, not two, because the vault cannot tell them
 * apart: it authorises an intent by validating a signature over an order hash, and what makes an
 * order part of a schedule lives in its app data — an off-chain document the chain never sees. A
 * TWAP is a series of orders each of which looks exactly like a limit order from in here.
 *
 * Unwinding is not a permission. Withdrawing a position, removing liquidity, claiming fees and
 * cancelling an order all move money back INTO the vault, so they stay open to any live manager;
 * what the bits govern is putting money out.
 */
uint32 constant PERM_YIELD = 1 << 0;
uint32 constant PERM_SUPPLY = 1 << 1;
uint32 constant PERM_MARKET_TRADE = 1 << 2;
uint32 constant PERM_MARKET_MAKER = 1 << 3;
uint32 constant PERM_INTENT = 1 << 4;

