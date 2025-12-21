// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {AddressZero, AlreadyInitialized} from "../src/interfaces/Errors.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {Migrator} from "../src/Migrator.sol";
import {WhiteList} from "../src/WhiteList.sol";

contract BittyVaultTest is Test {
    BittyVault public bittyVault;
    WETH public weth;
    address public migratorAddress;
    address public whiteListAddress;
    address public grantorAddress;

    function setUp() public {
        weth = new WETH();
        bittyVault = new BittyVault();
        migratorAddress = address(new Migrator());
        whiteListAddress = address(new WhiteList());
        grantorAddress = makeAddr("grantorAddress");
    }

    function test_InitErrorWithWethAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        bittyVault.initialize(
            address(grantorAddress),
            address(whiteListAddress),
            address(migratorAddress),
            address(0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_InitErrorWithAlreadyInitialized() public {
        bittyVault.initialize(
            address(grantorAddress),
            address(whiteListAddress),
            address(migratorAddress),
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        vm.expectRevert(AlreadyInitialized.selector);
        bittyVault.initialize(
            address(grantorAddress),
            address(whiteListAddress),
            address(migratorAddress),
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_SetTrustToIrrevocable() public {
        vm.startPrank(grantorAddress);
        bittyVault.initialize(
            address(grantorAddress),
            address(whiteListAddress),
            address(migratorAddress),
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        bittyVault.setToIrrevocable();
        vm.stopPrank();
        assertEq(bittyVault.revocable(), false);
    }

    function test_AutoIrrevocableAfterNoPing() public {
        vm.startPrank(grantorAddress);
        bittyVault.initialize(
            address(grantorAddress),
            address(whiteListAddress),
            address(migratorAddress),
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        bittyVault.setAutoIrrevocableAfterNoPing(1);
        vm.stopPrank();
        vm.warp(block.timestamp + 2);
        assertEq(bittyVault.revocable(), false);
    }

    function test_RevocableAfterPing() public {
        vm.startPrank(grantorAddress);
        bittyVault.initialize(
            address(grantorAddress),
            address(whiteListAddress),
            address(migratorAddress),
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        bittyVault.setAutoIrrevocableAfterNoPing(2);
        bittyVault.grantorPing();
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        assertEq(bittyVault.revocable(), true);
    }
}
