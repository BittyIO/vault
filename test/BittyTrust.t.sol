// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

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

contract BittyTrustTest is Test {
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

    function test_AutoIrrevocableAfterNoPing() public {
        bittyTrust.initialize(address(this));
        bittyTrust.setAutoIrrevocableAfterNoPing(1);
        vm.warp(block.timestamp + 2);
        assertEq(bittyTrust.revocable(), false);
    }

    function test_RevocableAfterPing() public {
        bittyTrust.initialize(address(this));
        bittyTrust.setAutoIrrevocableAfterNoPing(2);
        bittyTrust.ping();
        vm.warp(block.timestamp + 1);
        assertEq(bittyTrust.revocable(), true);
    }

    function test_SetWETHCanOnlyBeCalledOnce() public {
        BittyTrust newTrust = new BittyTrust();
        address weth1 = address(0x1);
        address weth2 = address(0x2);

        assertEq(address(newTrust.weth()), address(0));
        newTrust.setWETH(weth1);
        assertEq(address(newTrust.weth()), weth1);
        assertTrue(address(newTrust.weth()) != address(0));

        vm.expectRevert(BittyTrust.WETHAlreadySet.selector);
        newTrust.setWETH(weth2);
    }

    function test_SetWETHRevertsOnZeroAddress() public {
        BittyTrust newTrust = new BittyTrust();
        vm.expectRevert(BittyTrust.AddressZero.selector);
        newTrust.setWETH(address(0));
    }
}
