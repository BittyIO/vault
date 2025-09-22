// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {BittyTrust} from "../src/BittyTrust.sol";

contract BittyTrustTest is Test {
    BittyTrust public bittyTrust;

    function setUp() public {
        bittyTrust = new BittyTrust();
    }

    function test_InitErrorWithGrantorAddressZero() public {
        vm.expectRevert(BittyTrust.AddressZero.selector);
        bittyTrust.initialize(address(0));
    }

    function test_InitErrorWithAlreadyInitialized() public {
        bittyTrust.initialize(address(1));
        vm.expectRevert(BittyTrust.AlreadyInitialized.selector);
        bittyTrust.initialize(address(1));
    }

    

}
