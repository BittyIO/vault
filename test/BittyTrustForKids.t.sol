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

contract BittyTrustForKidsTest is Test {
    BittyTrust public bittyTrustForKids;
    address kidAddress;
    address trusteeAddress;
    MockWETH mockWETH;

    function setUp() public {
        mockWETH = new MockWETH();
        bittyTrustForKids = new BittyTrust();
        bittyTrustForKids.setWETH(address(mockWETH));
        kidAddress = makeAddr("alice");
        trusteeAddress = makeAddr("trustee");
        bittyTrustForKids.initialize(address(this));
        bittyTrustForKids.setTrustee(trusteeAddress);
        bittyTrustForKids.setBeneficiary(kidAddress);
        bittyTrustForKids.setToIrrevocable();
    }

    function test_BeneficiaryIsRight() public view {
        assertEq(bittyTrustForKids.beneficiary(), kidAddress);
    }

    function test_TrustIsIrrevocable() public view {
        assertTrue(bittyTrustForKids.isIrrevocable());
    }

    function test_TrustNotStartedBeforeTheStartDay() public {
        bittyTrustForKids.setStartDistributionTimestamp(block.timestamp + 1 days);
        assertFalse(bittyTrustForKids.distributionStarted());
        vm.warp(block.timestamp + 2 days);
        assertTrue(bittyTrustForKids.distributionStarted());
    }

    function test_TrustTurnETHToWETH() public {
        vm.deal(address(bittyTrustForKids), 10 ether);
        assertEq(bittyTrustForKids.getETHBalance(), 10 ether);
        assertEq(bittyTrustForKids.getWETHBalance(), 0);

        vm.prank(trusteeAddress);
        bittyTrustForKids.turnETHToWETH();

        assertEq(bittyTrustForKids.getETHBalance(), 0);
        assertEq(bittyTrustForKids.getWETHBalance(), 10 ether);
    }

    function test_TrustBeneficiaryChangeAddress() public {
        assertEq(bittyTrustForKids.beneficiary(), kidAddress);
        address newKidAddress = makeAddr("aliceNewAddress");
        bittyTrustForKids.setBeneficiary(newKidAddress);
        assertEq(bittyTrustForKids.beneficiary(), newKidAddress);
    }
}
