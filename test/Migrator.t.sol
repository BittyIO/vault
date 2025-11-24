// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {Migrator} from "../src/Migrator.sol";
import {IMigrator} from "../src/interfaces/IMigrator.sol";

contract MigratorTest is Test {
    Migrator public migrator;
    address public owner;
    address public nonOwner;
    address public vault1;
    address public vault2;
    address public nextVault1;
    address public nextVault2;

    function setUp() public {
        owner = address(this);
        nonOwner = makeAddr("nonOwner");
        migrator = new Migrator();
        vault1 = makeAddr("vault1");
        vault2 = makeAddr("vault2");
        nextVault1 = makeAddr("nextVault1");
        nextVault2 = makeAddr("nextVault2");
    }

    function test_InitialOwnerIsDeployer() public view {
        assertEq(migrator.owner(), owner, "Owner should be deployer");
    }

    function test_NextVaultReturnsZeroInitially() public view {
        address result = migrator.nextVault(vault1);
        assertEq(result, address(0), "Next vault should be zero address initially");
    }

    function test_OwnerCanSetNextVault() public {
        migrator.setNextVault(vault1, nextVault1);
        address result = migrator.nextVault(vault1);
        assertEq(result, nextVault1, "Next vault should be set correctly");
    }

    function test_NonOwnerCannotSetNextVault() public {
        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        migrator.setNextVault(vault1, nextVault1);
    }

    function test_CanUpdateNextVault() public {
        migrator.setNextVault(vault1, nextVault1);
        assertEq(migrator.nextVault(vault1), nextVault1, "First next vault should be set");

        address newNextVault = makeAddr("newNextVault");
        migrator.setNextVault(vault1, newNextVault);
        assertEq(migrator.nextVault(vault1), newNextVault, "Next vault should be updated");
    }

    function test_CanSetDifferentNextVaultsForDifferentVaults() public {
        migrator.setNextVault(vault1, nextVault1);
        migrator.setNextVault(vault2, nextVault2);

        assertEq(migrator.nextVault(vault1), nextVault1, "Vault1 next vault should be set");
        assertEq(migrator.nextVault(vault2), nextVault2, "Vault2 next vault should be set");
        assertTrue(nextVault1 != nextVault2, "Next vaults should be different");
    }

    function test_CanSetNextVaultToZeroAddress() public {
        migrator.setNextVault(vault1, nextVault1);
        assertEq(migrator.nextVault(vault1), nextVault1, "Next vault should be set");

        migrator.setNextVault(vault1, address(0));
        assertEq(migrator.nextVault(vault1), address(0), "Next vault should be reset to zero");
    }

    function test_NewOwnerCanSetNextVault() public {
        address newOwner = makeAddr("newOwner");
        migrator.transferOwnership(newOwner);

        vm.prank(newOwner);
        migrator.setNextVault(vault1, nextVault1);
        assertEq(migrator.nextVault(vault1), nextVault1, "New owner should be able to set next vault");
    }

    function test_OldOwnerCannotSetNextVaultAfterTransfer() public {
        address newOwner = makeAddr("newOwner");
        migrator.transferOwnership(newOwner);

        vm.expectRevert("Ownable: caller is not the owner");
        migrator.setNextVault(vault1, nextVault1);
    }

    function test_PublicMappingAccess() public {
        migrator.setNextVault(vault1, nextVault1);
        address result = migrator.nextVaults(vault1);
        assertEq(result, nextVault1, "Public mapping should be accessible");
    }
}

