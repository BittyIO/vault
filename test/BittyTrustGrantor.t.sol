// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BittyTrust} from "../src/BittyTrust.sol";

interface IWETH {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
}

contract MockWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract BittyTrustGrantorTest is Test {
    BittyTrust public bittyTrust;
    MockWETH public mockWETH;

    function setUp() public {
        mockWETH = new MockWETH();
        bittyTrust = new BittyTrust();
        bittyTrust.setWETH(address(mockWETH));
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

    function test_SetTrustToIrrevocable() public {
        bittyTrust.initialize(address(this));
        bittyTrust.setToIrrevocable();
        assertEq(bittyTrust.revocable(), false);
    }

    function test_RevocableAfterPing() public {
        bittyTrust.initialize(address(this));
        bittyTrust.setAutoIrrevocableAfterNoPing(2);
        bittyTrust.ping();
        vm.warp(block.timestamp + 1);
        assertEq(bittyTrust.revocable(), true);
    }

    function test_AutoIrrevocableAfterNoPing() public {
        bittyTrust.initialize(address(this));
        bittyTrust.setAutoIrrevocableAfterNoPing(1);
        vm.warp(block.timestamp + 2);
        assertEq(bittyTrust.revocable(), false);
    }
}
