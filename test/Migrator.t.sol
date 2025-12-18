// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {Migrator} from "../src/Migrator.sol";
import {SimpleMockVault} from "./mock/SimpleMockVault.sol";
import {IVersionized} from "../src/interfaces/IVersionized.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

contract MigratorTest is Test {
    Migrator public migrator;
    address public owner;
    address public nonOwner;
    SimpleMockVault public vaultV1;
    SimpleMockVault public vaultV2;
    SimpleMockVault public vaultV3;
    bytes public argsV1;
    bytes public argsV2;
    bytes public argsV3;

    function setUp() public {
        owner = makeAddr("owner");
        nonOwner = makeAddr("nonOwner");
        migrator = new Migrator();

        // Transfer ownership to owner
        vm.prank(address(this));
        migrator.transferOwnership(owner);

        // Create mock vault implementations
        vaultV1 = new SimpleMockVault(1);
        vaultV2 = new SimpleMockVault(2);
        vaultV3 = new SimpleMockVault(3);

        // Prepare initialization args (version encoded as uint256)
        argsV1 = abi.encode(uint256(1));
        argsV2 = abi.encode(uint256(2));
        argsV3 = abi.encode(uint256(3));
    }

    // ============ setVersionizedVault Tests ============

    function test_SetVersionizedVault_Success() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);

        (address vault, bytes memory args) = migrator.versionToVault(1);
        assertEq(vault, address(vaultV1), "Vault address should match");
        assertEq(args, argsV1, "Args should match");
        assertEq(migrator.vaultToVersion(address(vaultV1)), 1, "Vault version should be 1");
    }

    function test_SetVersionizedVault_OnlyOwner() public {
        vm.expectRevert();
        vm.prank(nonOwner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
    }

    function test_SetVersionizedVault_VaultAlreadyVersioned() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);

        vm.expectRevert(Migrator.VaultAlreadyVersioned.selector);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
    }

    function test_SetVersionizedVault_VersionAlreadyUsed() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);

        SimpleMockVault anotherVaultV1 = new SimpleMockVault(1);
        vm.expectRevert(Migrator.VersionAlreadyUsed.selector);
        vm.prank(owner);
        migrator.setVersionizedVault(address(anotherVaultV1), argsV1, false);
    }

    function test_SetVersionizedVault_ForceUpdate() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);

        SimpleMockVault newVaultV1 = new SimpleMockVault(1);
        bytes memory newArgs = abi.encode(uint256(1), "new args");

        vm.prank(owner);
        migrator.setVersionizedVault(address(newVaultV1), newArgs, true);

        (address vault, bytes memory args) = migrator.versionToVault(1);
        assertEq(vault, address(newVaultV1), "Vault should be updated");
        assertEq(args, newArgs, "Args should be updated");
        assertEq(migrator.vaultToVersion(address(newVaultV1)), 1, "New vault version should be 1");
    }

    function test_SetVersionizedVault_MultipleVersions() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);

        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV2), argsV2, false);

        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV3), argsV3, false);

        (address v1,) = migrator.versionToVault(1);
        (address v2,) = migrator.versionToVault(2);
        (address v3,) = migrator.versionToVault(3);

        assertEq(v1, address(vaultV1), "Version 1 should match");
        assertEq(v2, address(vaultV2), "Version 2 should match");
        assertEq(v3, address(vaultV3), "Version 3 should match");
    }

    // ============ createVersionVault Tests ============

    function test_CreateVersionVault_Success() public {
        // Set up versions
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV2), argsV2, false);

        // Create an instance of vault V1
        SimpleMockVault fromVault = new SimpleMockVault(1);
        fromVault.initializeFromPreviousVersion(address(0), argsV1);

        // Create next version vault
        address nextVault = migrator.createVersionVault(address(fromVault), 2, "salt");

        assertTrue(nextVault != address(0), "Next vault should be created");
        assertEq(IVersionized(nextVault).version(), 2, "Next vault version should be 2");
        assertEq(migrator.nextVersionVaults(address(fromVault)), nextVault, "Next vault mapping should be set");
    }

    function test_CreateVersionVault_InvalidVersion() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);

        SimpleMockVault fromVault = new SimpleMockVault(1);
        fromVault.initializeFromPreviousVersion(address(0), argsV1);

        // toVersion <= fromVersion should revert
        vm.expectRevert(Migrator.InvalidVersion.selector);
        migrator.createVersionVault(address(fromVault), 1, "salt");

        vm.expectRevert(Migrator.InvalidVersion.selector);
        migrator.createVersionVault(address(fromVault), 0, "salt");
    }

    function test_CreateVersionVault_NoNextVersionVault() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
        // Don't set version 2

        SimpleMockVault fromVault = new SimpleMockVault(1);
        fromVault.initializeFromPreviousVersion(address(0), argsV1);

        vm.expectRevert(Migrator.NoNextVersionVault.selector);
        migrator.createVersionVault(address(fromVault), 2, "salt");
    }

    function test_CreateVersionVault_VersionJump() public {
        // Set up versions 1, 2, 3
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV2), argsV2, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV3), argsV3, false);

        SimpleMockVault fromVault = new SimpleMockVault(1);
        fromVault.initializeFromPreviousVersion(address(0), argsV1);

        // Create vault jumping from version 1 to 3
        address finalVault = migrator.createVersionVault(address(fromVault), 3, "salt");

        assertEq(IVersionized(finalVault).version(), 3, "Final vault version should be 3");

        // Verify intermediate vault was created
        address intermediateVault = migrator.nextVersionVaults(address(fromVault));
        assertTrue(intermediateVault != address(0), "Intermediate vault should exist");
        assertEq(IVersionized(intermediateVault).version(), 2, "Intermediate vault version should be 2");
    }

    function test_CreateVersionVault_ReturnsExistingVault() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV2), argsV2, false);

        SimpleMockVault fromVault = new SimpleMockVault(1);
        fromVault.initializeFromPreviousVersion(address(0), argsV1);

        // Create first time
        address nextVault1 = migrator.createVersionVault(address(fromVault), 2, "salt");

        // Create second time with same salt - should return same vault
        address nextVault2 = migrator.createVersionVault(address(fromVault), 2, "salt");

        assertEq(nextVault1, nextVault2, "Should return same vault");
    }

    function test_CreateVersionVault_DifferentSaltReturnsSameAddress() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV2), argsV2, false);

        SimpleMockVault fromVault = new SimpleMockVault(1);
        fromVault.initializeFromPreviousVersion(address(0), argsV1);

        // Create with salt1
        address nextVault1 = migrator.createVersionVault(address(fromVault), 2, "salt1");

        // Create with salt2 - should return same vault because mapping is based on fromVault
        address nextVault2 = migrator.createVersionVault(address(fromVault), 2, "salt2");

        assertEq(nextVault1, nextVault2, "Should return same vault regardless of salt");
    }

    function test_CreateVersionVault_VaultAlreadyDeployed() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV2), argsV2, false);

        SimpleMockVault fromVault = new SimpleMockVault(1);
        fromVault.initializeFromPreviousVersion(address(0), argsV1);

        // Calculate the address that will be deployed
        // Note: Migrator uses predictDeterministicAddress(implementation, salt) which uses address(this) as deployer
        // So we need to use address(migrator) as deployer
        bytes32 saltHash = keccak256(abi.encodePacked(address(fromVault), "salt"));
        (address vaultImplementation,) = migrator.versionToVault(2);
        address predictedAddress = Clones.predictDeterministicAddress(vaultImplementation, saltHash, address(migrator));

        // Deploy a contract at that address manually (simulating MEV attack)
        // Use a minimal contract bytecode that will pass code.length > 0 check
        bytes memory code =
            hex"6080604052348015600f57600080fd5b506004361060325760003560e01c8063c2985578146037575b600080fd5b603d603f565b005b600080fdfea2646970667358221220";
        vm.etch(predictedAddress, code);

        // Verify code was set
        assertGt(predictedAddress.code.length, 0, "Code should be set");

        // Try to create vault - should revert
        vm.expectRevert(Migrator.VaultAlreadyDeployed.selector);
        migrator.createVersionVault(address(fromVault), 2, "salt");
    }

    // ============ versionVault Tests ============

    function test_VersionVault_Success() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV2), argsV2, false);

        SimpleMockVault fromVault = new SimpleMockVault(1);
        fromVault.initializeFromPreviousVersion(address(0), argsV1);

        // Create the vault first
        address createdVault = migrator.createVersionVault(address(fromVault), 2, "salt");

        // Query version vault
        address queriedVault = migrator.versionVault(address(fromVault), 2);

        assertEq(queriedVault, createdVault, "Queried vault should match created vault");
        assertEq(IVersionized(queriedVault).version(), 2, "Version should be 2");
    }

    function test_VersionVault_InvalidVersion() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);

        SimpleMockVault fromVault = new SimpleMockVault(1);
        fromVault.initializeFromPreviousVersion(address(0), argsV1);

        // toVersion <= fromVersion should revert
        vm.expectRevert(Migrator.InvalidVersion.selector);
        migrator.versionVault(address(fromVault), 1);

        vm.expectRevert(Migrator.InvalidVersion.selector);
        migrator.versionVault(address(fromVault), 0);
    }

    function test_VersionVault_NoNextVersionVault() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);

        SimpleMockVault fromVault = new SimpleMockVault(1);
        fromVault.initializeFromPreviousVersion(address(0), argsV1);

        vm.expectRevert(Migrator.NoNextVersionVault.selector);
        migrator.versionVault(address(fromVault), 2);
    }

    function test_VersionVault_VersionJump() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV2), argsV2, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV3), argsV3, false);

        SimpleMockVault fromVault = new SimpleMockVault(1);
        fromVault.initializeFromPreviousVersion(address(0), argsV1);

        // Create vaults first
        migrator.createVersionVault(address(fromVault), 3, "salt");

        // Query version 3
        address queriedVault = migrator.versionVault(address(fromVault), 3);

        assertEq(IVersionized(queriedVault).version(), 3, "Version should be 3");
    }

    function test_VersionVault_IntermediateVersions() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV2), argsV2, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV3), argsV3, false);

        SimpleMockVault fromVault = new SimpleMockVault(1);
        fromVault.initializeFromPreviousVersion(address(0), argsV1);

        // Create vaults up to version 3
        migrator.createVersionVault(address(fromVault), 3, "salt");

        // Query version 2
        address v2Vault = migrator.versionVault(address(fromVault), 2);
        assertEq(IVersionized(v2Vault).version(), 2, "Version 2 should be correct");

        // Query version 3
        address v3Vault = migrator.versionVault(address(fromVault), 3);
        assertEq(IVersionized(v3Vault).version(), 3, "Version 3 should be correct");
    }

    // ============ Integration Tests ============

    function test_FullMigrationFlow() public {
        // Set up all versions
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV2), argsV2, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV3), argsV3, false);

        // Create initial vault
        SimpleMockVault initialVault = new SimpleMockVault(1);
        initialVault.initializeFromPreviousVersion(address(0), argsV1);

        // Migrate to version 2
        address v2Vault = migrator.createVersionVault(address(initialVault), 2, "migration1");
        assertEq(IVersionized(v2Vault).version(), 2, "V2 vault version should be 2");

        // Migrate from v2 to v3
        address v3Vault = migrator.createVersionVault(v2Vault, 3, "migration2");
        assertEq(IVersionized(v3Vault).version(), 3, "V3 vault version should be 3");

        // Verify chain
        assertEq(migrator.nextVersionVaults(address(initialVault)), v2Vault, "Initial -> V2 mapping");
        assertEq(migrator.nextVersionVaults(v2Vault), v3Vault, "V2 -> V3 mapping");
    }

    function test_MultipleVaultsSameVersion() public {
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV1), argsV1, false);
        vm.prank(owner);
        migrator.setVersionizedVault(address(vaultV2), argsV2, false);

        // Create two different vaults of version 1
        SimpleMockVault vault1A = new SimpleMockVault(1);
        vault1A.initializeFromPreviousVersion(address(0), argsV1);

        SimpleMockVault vault1B = new SimpleMockVault(1);
        vault1B.initializeFromPreviousVersion(address(0), argsV1);

        // Create next version vaults for both
        address nextVaultA = migrator.createVersionVault(address(vault1A), 2, "saltA");
        address nextVaultB = migrator.createVersionVault(address(vault1B), 2, "saltB");

        // They should be different addresses
        assertTrue(nextVaultA != nextVaultB, "Different vaults should create different next vaults");
        assertEq(IVersionized(nextVaultA).version(), 2, "Next vault A version should be 2");
        assertEq(IVersionized(nextVaultB).version(), 2, "Next vault B version should be 2");
    }
}

