// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";

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

contract BittyVaultForKidsTest is Test {
    BittyVault public bittyVaultForKids;
    address kidAddress;
    address trusteeAddress;
    MockWETH mockWETH;

    function setUp() public {
        mockWETH = new MockWETH();
        bittyVaultForKids = new BittyVault();
        bittyVaultForKids.initialize(
            address(this), address(mockWETH), address(0), address(0), address(0), address(0), address(0)
        );
        kidAddress = makeAddr("alice");
        trusteeAddress = makeAddr("trustee");
        bittyVaultForKids.setTrustee(trusteeAddress);
        bittyVaultForKids.setBeneficiary(kidAddress);
        bittyVaultForKids.setToIrrevocable();
    }

    function test_BeneficiaryIsRight() public view {
        assertEq(bittyVaultForKids.beneficiary(), kidAddress);
    }

    function test_TrustIsIrrevocable() public view {
        assertTrue(bittyVaultForKids.isIrrevocable());
    }

    function test_TrustNotStartedBeforeTheStartDay() public {
        bittyVaultForKids.setStartDistributionTimestamp(block.timestamp + 1 days);
        assertFalse(bittyVaultForKids.distributionStarted());
        vm.warp(block.timestamp + 2 days);
        assertTrue(bittyVaultForKids.distributionStarted());
    }

    function test_TrustTurnETHToWETH() public {
        vm.deal(address(bittyVaultForKids), 10 ether);
        assertEq(bittyVaultForKids.getETHBalance(), 10 ether);
        assertEq(bittyVaultForKids.getWETHBalance(), 0);

        vm.prank(trusteeAddress);
        bittyVaultForKids.turnETHToWETH();

        assertEq(bittyVaultForKids.getETHBalance(), 0);
        assertEq(bittyVaultForKids.getWETHBalance(), 10 ether);
    }

    function test_TrustBeneficiaryChangeAddress() public {
        assertEq(bittyVaultForKids.beneficiary(), kidAddress);
        address newKidAddress = makeAddr("aliceNewAddress");
        bittyVaultForKids.setBeneficiary(newKidAddress);
        assertEq(bittyVaultForKids.beneficiary(), newKidAddress);
    }
}
