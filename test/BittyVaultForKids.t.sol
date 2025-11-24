// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {MockWETH} from "./mock/MockWETH.sol";

contract BittyVaultForKidsTest is Test {
    BittyVault public bittyVaultForKids;
    address grantor;
    address kidAddress;
    address trusteeAddress;
    MockWETH mockWETH;
    address public whiteListAddress;

    function setUp() public {
        mockWETH = new MockWETH();
        bittyVaultForKids = new BittyVault();
        whiteListAddress = address(new WhiteList());
        grantor = makeAddr("grantor");
        kidAddress = makeAddr("alice");
        bittyVaultForKids.initialize(
            grantor,
            address(mockWETH),
            whiteListAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        kidAddress = makeAddr("alice");
        trusteeAddress = makeAddr("trustee");
        vm.prank(grantor);
        bittyVaultForKids.setTrustee(trusteeAddress);
        vm.prank(grantor);
        bittyVaultForKids.setBeneficiary(kidAddress);
    }

    function test_BeneficiaryIsRight() public view {
        assertEq(bittyVaultForKids.beneficiary(), kidAddress);
    }

    function test_TrustIsIrrevocable() public {
        vm.prank(grantor);
        bittyVaultForKids.setToIrrevocable();
        assertTrue(bittyVaultForKids.isIrrevocable());
    }

    function test_TrustNotStartedBeforeTheStartDay() public {
        vm.prank(grantor);
        bittyVaultForKids.setStartDistributionTimestamp(block.timestamp + 1 days);
        assertFalse(bittyVaultForKids.distributionStarted());
        vm.warp(block.timestamp + 2 days);
        assertTrue(bittyVaultForKids.distributionStarted());
    }

    function test_TrustTurnETHToWETH() public {
        vm.deal(address(bittyVaultForKids), 10 ether);
        assertEq(address(bittyVaultForKids).balance, 10 ether);
        assertEq(mockWETH.balanceOf(address(bittyVaultForKids)), 0);

        vm.prank(trusteeAddress);
        bittyVaultForKids.turnETHToWETH();

        assertEq(address(bittyVaultForKids).balance, 0);
        assertEq(mockWETH.balanceOf(address(bittyVaultForKids)), 10 ether);
    }

    function test_TrustBeneficiaryChangeAddress() public {
        assertEq(bittyVaultForKids.beneficiary(), kidAddress);
        address newKidAddress = makeAddr("aliceNewAddress");
        vm.prank(grantor);
        bittyVaultForKids.setBeneficiary(newKidAddress);
        assertEq(bittyVaultForKids.beneficiary(), newKidAddress);
    }
}
