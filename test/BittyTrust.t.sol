// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {BittyTrust} from "../src/BittyTrust.sol";

contract BittyTrustTest is Test {
    BittyTrust public bittyTrust;

    function setUp() public {
        bittyTrust = new BittyTrust();
    }

    function test_init_usd_value_zero() public view {
        assertEq(bittyTrust.usdValue(), 0);
    }
}
