// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {ITrust} from "../src/interfaces/ITrust.sol";
import {AddressZero, AlreadyInitialized} from "../src/interfaces/Errors.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";

contract BittyVaultTest is Test {
    BittyVault public bittyVault;
    WETH public mockWETH;

    function setUp() public {
        mockWETH = new WETH();
        bittyVault = new BittyVault();
    }

    function test_InitErrorWithGrantorAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        bittyVault.initialize(address(0));
    }

    function test_InitErrorWithAlreadyInitialized() public {
        bittyVault.initialize(address(1));
        vm.expectRevert(AlreadyInitialized.selector);
        bittyVault.initialize(address(1));
    }

    function test_SetTrustToIrrevocable() public {
        bittyVault.initialize(address(this));
        bittyVault.setToIrrevocable();
        assertEq(bittyVault.revocable(), false);
    }

    function test_AutoIrrevocableAfterNoPing() public {
        bittyVault.initialize(address(this));
        bittyVault.setAutoIrrevocableAfterNoPing(1);
        vm.warp(block.timestamp + 2);
        assertEq(bittyVault.revocable(), false);
    }

    function test_RevocableAfterPing() public {
        bittyVault.initialize(address(this));
        bittyVault.setAutoIrrevocableAfterNoPing(2);
        bittyVault.ping();
        vm.warp(block.timestamp + 1);
        assertEq(bittyVault.revocable(), true);
    }
}
