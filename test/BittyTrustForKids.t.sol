// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BittyTrust} from "../src/BittyTrust.sol";

contract BittyTrustTest is Test {
    BittyTrust public bittyTrustForKids;

    function setUp() public {
        bittyTrustForKids = new BittyTrust();
        bittyTrustForKids.initialize(address(this));
    }
}
