// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {AddressZero} from "../src/interfaces/Errors.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {Migrator} from "../src/Migrator.sol";

contract BittyVaultGrantorTest is Test {
    BittyVault public bittyVault;
    WETH public mockWETH;
    address public whiteListAddress;
    address public migratorAddress;

    function setUp() public {
        mockWETH = new WETH();
        bittyVault = new BittyVault();
        whiteListAddress = address(new WhiteList());
        migratorAddress = address(new Migrator());
        bittyVault.initialize(
            address(this),
            address(mockWETH),
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_InitErrorWithGrantorAddressZero() public {
        BittyVault newVault = new BittyVault();
        vm.expectRevert(AddressZero.selector);
        newVault.initialize(
            address(0),
            address(mockWETH),
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_InitErrorWithAlreadyInitialized() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(1),
            address(mockWETH),
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        vm.expectRevert();
        newVault.initialize(
            address(1),
            address(mockWETH),
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_SetTrustToIrrevocable() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            address(mockWETH),
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        newVault.setToIrrevocable();
        assertEq(newVault.revocable(), false);
    }

    function test_RevocableAfterPing() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            address(mockWETH),
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        newVault.setAutoIrrevocableAfterNoPing(2);
        newVault.ping();
        vm.warp(block.timestamp + 1);
        assertEq(newVault.revocable(), true);
    }

    function test_AutoIrrevocableAfterNoPing() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(address(this), address(1), migratorAddress);
        newVault.setAutoIrrevocableAfterNoPing(1);
        vm.warp(block.timestamp + 2);
        assertEq(newVault.revocable(), false);
    }

    function test_ChangeGrantorAddressErrorWithNotRevocable() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(address(this), address(1), migratorAddress);
        newVault.setToIrrevocable();
        vm.expectRevert("Only revocable");
        newVault.changeGrantorAddress(address(1));
    }

    function test_ChangeGrantorAddressErrorWithAddressZero() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(address(this), address(1), migratorAddress);
        vm.expectRevert(AddressZero.selector);
        newVault.changeGrantorAddress(address(0));
    }
}
