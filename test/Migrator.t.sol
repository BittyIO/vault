// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {Migrator} from "../src/Migrator.sol";
import {IMigrator} from "../src/interfaces/IMigrator.sol";
import {IVersionizedVault} from "../src/interfaces/IVersionizedVault.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

contract MigratorTest is Test {
    Migrator public migrator;
    address public owner;
    address public nonOwner;
    address public trustee1;
    address public trustee2;

    MockVersionizedVault public vaultV1;
    MockVersionizedVault public vaultV2;
    MockVersionizedVault public vaultV3;

    function setUp() public {
        owner = address(this);
        nonOwner = makeAddr("nonOwner");
        trustee1 = makeAddr("trustee1");
        trustee2 = makeAddr("trustee2");
        migrator = new Migrator();

        // Deploy implementation vaults
        vaultV1 = new MockVersionizedVault(1);
        vaultV2 = new MockVersionizedVault(2);
        vaultV3 = new MockVersionizedVault(3);
    }

    // ============ setVersionizedVault Tests ============

    function test_SetVersionizedVault_Success() public {
        bytes memory args = abi.encode("test args");
        migrator.setVersionizedVault(address(vaultV1), args, false);

        (address vault, bytes memory storedArgs) = migrator.versionToVault(1);
        assertEq(vault, address(vaultV1), "Vault address should be set");
        assertEq(keccak256(storedArgs), keccak256(args), "Args should be stored");
        assertEq(migrator.vaultToVersion(address(vaultV1)), 1, "Vault version should be set");
    }

    function test_SetVersionizedVault_OnlyOwner() public {
        bytes memory args = abi.encode("test args");

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        migrator.setVersionizedVault(address(vaultV1), args, false);
    }

    function test_SetVersionizedVault_MultipleVersions() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");
        bytes memory args3 = abi.encode("v3 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);
        migrator.setVersionizedVault(address(vaultV3), args3, false);

        (address v1,) = migrator.versionToVault(1);
        (address v2,) = migrator.versionToVault(2);
        (address v3,) = migrator.versionToVault(3);

        assertEq(v1, address(vaultV1), "V1 should be set");
        assertEq(v2, address(vaultV2), "V2 should be set");
        assertEq(v3, address(vaultV3), "V3 should be set");
    }

    function test_SetVersionizedVault_VaultAlreadyVersioned() public {
        bytes memory args = abi.encode("test args");
        migrator.setVersionizedVault(address(vaultV1), args, false);

        vm.expectRevert(Migrator.VaultAlreadyVersioned.selector);
        migrator.setVersionizedVault(address(vaultV1), args, false);
    }

    function test_SetVersionizedVault_VersionAlreadyUsed() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v1 duplicate args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);

        // Try to set another vault with the same version
        MockVersionizedVault vaultV1Duplicate = new MockVersionizedVault(1);
        vm.expectRevert(Migrator.VersionAlreadyUsed.selector);
        migrator.setVersionizedVault(address(vaultV1Duplicate), args2, false);
    }

    function test_SetVersionizedVault_ForceUpdate() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v1 updated args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);

        // Force update should succeed
        migrator.setVersionizedVault(address(vaultV1), args2, true);

        (, bytes memory storedArgs) = migrator.versionToVault(1);
        assertEq(keccak256(storedArgs), keccak256(args2), "Args should be updated");
    }

    function test_SetVersionizedVault_ForceUpdateWithDifferentVault() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v1 new vault args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);

        // Create a new vault with same version
        MockVersionizedVault vaultV1New = new MockVersionizedVault(1);

        // Force update should allow replacing the vault
        migrator.setVersionizedVault(address(vaultV1New), args2, true);

        (address vault, bytes memory storedArgs) = migrator.versionToVault(1);
        assertEq(vault, address(vaultV1New), "Vault should be updated");
        assertEq(keccak256(storedArgs), keccak256(args2), "Args should be updated");
        assertEq(migrator.vaultToVersion(address(vaultV1New)), 1, "New vault version should be set");
    }

    // ============ createNextVersionVault Tests ============

    function test_CreateNextVersionVault_Success() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        vm.prank(trustee1);
        address nextVault = migrator.createNextVersionVault("test-salt", address(vaultV1));

        assertTrue(nextVault != address(0), "Next vault should be created");
        assertTrue(nextVault != address(vaultV2), "Next vault should be a clone, not the implementation");

        MockVersionizedVault nextVaultInstance = MockVersionizedVault(nextVault);
        assertEq(nextVaultInstance.version(), 2, "Next vault should be version 2");
        assertTrue(nextVaultInstance.initialized(), "Next vault should be initialized");
        assertEq(nextVaultInstance.previousVault(), address(vaultV1), "Previous vault should be set");
    }

    function test_CreateNextVersionVault_ReturnsExisting() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        vm.prank(trustee1);
        address nextVault1 = migrator.createNextVersionVault("test-salt", address(vaultV1));

        vm.prank(trustee1);
        address nextVault2 = migrator.createNextVersionVault("test-salt", address(vaultV1));

        assertEq(nextVault1, nextVault2, "Should return existing vault on second call");
    }

    function test_CreateNextVersionVault_DifferentTrusteesCreateDifferentVaults() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        vm.prank(trustee1);
        address nextVault1 = migrator.createNextVersionVault("test-salt", address(vaultV1));

        vm.prank(trustee2);
        address nextVault2 = migrator.createNextVersionVault("test-salt", address(vaultV1));

        assertTrue(nextVault1 != nextVault2, "Different trustees should create different vault instances");
        assertTrue(nextVault1 != address(0), "Next vault 1 should be created");
        assertTrue(nextVault2 != address(0), "Next vault 2 should be created");

        // Both should be version 2
        MockVersionizedVault nextVaultInstance1 = MockVersionizedVault(nextVault1);
        MockVersionizedVault nextVaultInstance2 = MockVersionizedVault(nextVault2);
        assertEq(nextVaultInstance1.version(), 2, "Next vault 1 should be version 2");
        assertEq(nextVaultInstance2.version(), 2, "Next vault 2 should be version 2");
    }

    function test_CreateNextVersionVault_NoNextVersion() public {
        bytes memory args1 = abi.encode("v1 args");
        migrator.setVersionizedVault(address(vaultV1), args1, false);

        vm.prank(trustee1);
        vm.expectRevert(Migrator.NoNextVersionVault.selector);
        migrator.createNextVersionVault("test-salt", address(vaultV1));
    }

    function test_CreateNextVersionVault_VaultNotRegistered() public {
        bytes memory args2 = abi.encode("v2 args");
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        // Create an unregistered vault instance
        MockVersionizedVault vaultInstance = new MockVersionizedVault(1);
        vaultInstance.initialize(address(0), "");

        vm.prank(trustee1);
        vm.expectRevert(Migrator.NoNextVersionVault.selector);
        migrator.createNextVersionVault("test-salt", address(vaultInstance));
    }

    function test_CreateNextVersionVault_InitializesWithArgs() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 initialization args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        vm.prank(trustee1);
        address nextVault = migrator.createNextVersionVault("test-salt", address(vaultV1));
        MockVersionizedVault nextVaultInstance = MockVersionizedVault(nextVault);

        assertEq(keccak256(nextVaultInstance.initArgs()), keccak256(args2), "Should initialize with correct args");
    }

    function test_CreateNextVersionVault_SequentialVersions() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");
        bytes memory args3 = abi.encode("v3 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);
        migrator.setVersionizedVault(address(vaultV3), args3, false);

        vm.prank(trustee1);
        address nextVaultV2 = migrator.createNextVersionVault("test-salt", address(vaultV1));
        assertEq(MockVersionizedVault(nextVaultV2).version(), 2, "First next vault should be version 2");

        // Register the V2 instance
        migrator.setVersionizedVault(address(nextVaultV2), args2, true);

        vm.prank(trustee1);
        address nextVaultV3 = migrator.createNextVersionVault("test-salt", address(nextVaultV2));
        assertEq(MockVersionizedVault(nextVaultV3).version(), 3, "Second next vault should be version 3");
    }

    function test_CreateNextVersionVault_VaultAlreadyDeployed_OnSecondCall() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        // First call: create next vault for vaultV1
        vm.prank(trustee1);
        address firstVault = migrator.createNextVersionVault("test-salt", address(vaultV1));
        assertTrue(firstVault != address(0), "First vault should be created");

        // Create a new vault instance (different address, same version)
        MockVersionizedVault vaultInstance2 = new MockVersionizedVault(1);
        vaultInstance2.initialize(address(0), "");
        migrator.setVersionizedVault(address(vaultInstance2), args1, true);

        // Second call: try to create next vault for vaultInstance2 with same trustee and salt
        // Since salt hash only includes msg.sender and salt (not _vault), it will calculate the same address
        // But the mapping is empty for vaultInstance2, so it will try to create
        // The address already has code from first call, so it should revert with VaultAlreadyDeployed
        vm.prank(trustee1);
        vm.expectRevert(Migrator.VaultAlreadyDeployed.selector);
        migrator.createNextVersionVault("test-salt", address(vaultInstance2));
    }

    // ============ nextVersionVault Tests ============

    function test_NextVersionVault_Success() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        vm.prank(trustee1);
        address createdVault = migrator.createNextVersionVault("test-salt", address(vaultV1));

        address queriedVault = migrator.nextVersionVault(trustee1, address(vaultV1));

        assertEq(createdVault, queriedVault, "Should return the created vault");
    }

    function test_NextVersionVault_NoNextVersion() public {
        bytes memory args1 = abi.encode("v1 args");
        migrator.setVersionizedVault(address(vaultV1), args1, false);

        vm.expectRevert(Migrator.NoNextVersionVault.selector);
        migrator.nextVersionVault(trustee1, address(vaultV1));
    }

    function test_NextVersionVault_UnregisteredVault() public {
        // Create an unregistered vault instance
        MockVersionizedVault vaultInstance = new MockVersionizedVault(1);
        vaultInstance.initialize(address(0), "");

        vm.expectRevert(Migrator.NoNextVersionVault.selector);
        migrator.nextVersionVault(trustee1, address(vaultInstance));
    }

    function test_NextVersionVault_DifferentTrustees() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        vm.prank(trustee1);
        address nextVault1 = migrator.createNextVersionVault("test-salt", address(vaultV1));

        vm.prank(trustee2);
        address nextVault2 = migrator.createNextVersionVault("test-salt", address(vaultV1));

        assertEq(migrator.nextVersionVault(trustee1, address(vaultV1)), nextVault1, "Should return trustee1's vault");
        assertEq(migrator.nextVersionVault(trustee2, address(vaultV1)), nextVault2, "Should return trustee2's vault");

        // Each trustee should only see their own vault
        assertTrue(
            migrator.nextVersionVault(trustee1, address(vaultV1))
                != migrator.nextVersionVault(trustee2, address(vaultV1)),
            "Different trustees should have different vaults"
        );
    }

    // ============ Public Mappings Tests ============

    function test_PublicMappings_Accessible() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        // Create vaultV1Instance for force update test
        MockVersionizedVault vaultV1Instance = new MockVersionizedVault(1);
        vaultV1Instance.initialize(address(0), "");
        migrator.setVersionizedVault(address(vaultV1Instance), args1, true);

        // Test versionToVault mapping (should point to vaultV1Instance after force update)
        (address vault, bytes memory args) = migrator.versionToVault(1);
        assertEq(vault, address(vaultV1Instance), "versionToVault should point to latest registered vault");
        assertEq(keccak256(args), keccak256(args1), "versionToVault args should be accessible");

        // Test vaultToVersion mapping
        uint256 version = migrator.vaultToVersion(address(vaultV1Instance));
        assertEq(version, 1, "vaultToVersion should be accessible");

        // Test vaultToNextVault mapping (after creation)
        vm.prank(trustee1);
        address nextVault = migrator.createNextVersionVault("test-salt", address(vaultV1Instance));
        address storedNextVault = migrator.nextVersionVaults(trustee1, address(vaultV1Instance));
        assertEq(storedNextVault, nextVault, "vaultToNextVault should be accessible");
    }

    function test_PublicMappings_VersionToVault() public {
        bytes memory args1 = abi.encode("v1 args");
        migrator.setVersionizedVault(address(vaultV1), args1, false);

        (address vault, bytes memory args) = migrator.versionToVault(1);
        assertEq(vault, address(vaultV1), "Should return correct vault");
        assertEq(keccak256(args), keccak256(args1), "Should return correct args");

        // Test non-existent version
        (address vault0, bytes memory args0) = migrator.versionToVault(999);
        assertEq(vault0, address(0), "Non-existent version should return zero address");
        assertEq(args0.length, 0, "Non-existent version should return empty args");
    }

    function test_PublicMappings_VaultToVersion() public {
        bytes memory args1 = abi.encode("v1 args");
        migrator.setVersionizedVault(address(vaultV1), args1, false);

        assertEq(migrator.vaultToVersion(address(vaultV1)), 1, "Should return correct version");
        assertEq(migrator.vaultToVersion(address(vaultV2)), 0, "Unregistered vault should return 0");
    }

    // ============ Ownership Tests ============

    function test_InitialOwnerIsDeployer() public view {
        assertEq(migrator.owner(), owner, "Owner should be deployer");
    }

    function test_TransferOwnership() public {
        address newOwner = makeAddr("newOwner");
        migrator.transferOwnership(newOwner);

        assertEq(migrator.owner(), newOwner, "New owner should be set immediately");
    }

    function test_NewOwnerCanSetNextVault() public {
        address newOwner = makeAddr("newOwner");
        migrator.transferOwnership(newOwner);

        bytes memory args = abi.encode("test args");
        vm.prank(newOwner);
        migrator.setVersionizedVault(address(vaultV1), args, false);

        (address vault,) = migrator.versionToVault(1);
        assertEq(vault, address(vaultV1), "New owner should be able to set vault");
    }

    function test_OldOwnerCannotSetAfterTransfer() public {
        address newOwner = makeAddr("newOwner");
        migrator.transferOwnership(newOwner);

        bytes memory args = abi.encode("test args");
        vm.expectRevert("Ownable: caller is not the owner");
        migrator.setVersionizedVault(address(vaultV1), args, false);
    }

    // ============ Edge Cases ============

    function test_CreateNextVersionVault_UninitializedVault() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        // Create a new vault instance but don't initialize it
        MockVersionizedVault uninitializedVault = new MockVersionizedVault(1);
        migrator.setVersionizedVault(address(uninitializedVault), args1, true);

        // createNextVersionVault should work even if the vault is not initialized
        // because initialization is not required for registration
        vm.prank(trustee1);
        address nextVault = migrator.createNextVersionVault("test-salt", address(uninitializedVault));
        assertTrue(nextVault != address(0), "Should create next vault successfully");
    }

    function test_SetVersionizedVault_EmptyArgs() public {
        bytes memory emptyArgs = "";
        migrator.setVersionizedVault(address(vaultV1), emptyArgs, false);

        (, bytes memory storedArgs) = migrator.versionToVault(1);
        assertEq(storedArgs.length, 0, "Empty args should be stored correctly");
    }

    function test_CreateNextVersionVault_WithEmptyArgs() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory emptyArgs = "";

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), emptyArgs, false);

        vm.prank(trustee1);
        address nextVault = migrator.createNextVersionVault("test-salt", address(vaultV1));
        MockVersionizedVault nextVaultInstance = MockVersionizedVault(nextVault);

        assertEq(nextVaultInstance.initArgs().length, 0, "Should initialize with empty args");
    }

    // ============ Deterministic Clone Tests ============

    function test_CreateNextVersionVault_DeterministicAddress() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        // Create vault with same salt and trustee should produce same address
        vm.prank(trustee1);
        address nextVault1 = migrator.createNextVersionVault("same-salt", address(vaultV1));

        vm.prank(trustee1);
        address nextVault2 = migrator.createNextVersionVault("same-salt", address(vaultV1));

        assertEq(nextVault1, nextVault2, "Same salt and trustee should create same address");
    }

    function test_CreateNextVersionVault_DifferentSaltReturnsSameAddress() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        vm.prank(trustee1);
        address nextVault1 = migrator.createNextVersionVault("salt-1", address(vaultV1));

        // Second call with different salt should return the same vault (already created)
        vm.prank(trustee1);
        address nextVault2 = migrator.createNextVersionVault("salt-2", address(vaultV1));

        assertEq(nextVault1, nextVault2, "Different salt should return same address for same trustee+vault");
    }

    function test_CreateNextVersionVault_DifferentTrusteeWithSameSaltCreatesDifferentAddress() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        vm.prank(trustee1);
        address nextVault1 = migrator.createNextVersionVault("same-salt", address(vaultV1));

        vm.prank(trustee2);
        address nextVault2 = migrator.createNextVersionVault("same-salt", address(vaultV1));

        assertTrue(nextVault1 != nextVault2, "Different trustee with same salt should create different addresses");
    }

    function test_CreateNextVersionVault_ReturnsExistingForSameSalt() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        vm.prank(trustee1);
        address nextVault1 = migrator.createNextVersionVault("test-salt", address(vaultV1));

        // Second call with same salt should return existing vault
        vm.prank(trustee1);
        address nextVault2 = migrator.createNextVersionVault("test-salt", address(vaultV1));

        assertEq(nextVault1, nextVault2, "Should return existing vault for same salt");
    }

    function test_CreateNextVersionVault_EmptySalt() public {
        bytes memory args1 = abi.encode("v1 args");
        bytes memory args2 = abi.encode("v2 args");

        migrator.setVersionizedVault(address(vaultV1), args1, false);
        migrator.setVersionizedVault(address(vaultV2), args2, false);

        vm.prank(trustee1);
        address nextVault = migrator.createNextVersionVault("", address(vaultV1));

        assertTrue(nextVault != address(0), "Should create vault with empty salt");
    }
}

/**
 * @title MockVersionizedVault
 * @notice Simple mock vault for testing Migrator functionality
 */
contract MockVersionizedVault is IVersionizedVault {
    uint256 public immutable override version;
    address public migrator;
    address public previousVault;
    bytes public initArgs;
    bool public initialized;

    constructor(uint256 _version) {
        version = _version;
    }

    function initialize(address previousVersionVaultAddress, bytes memory args) external override {
        require(!initialized, "Already initialized");
        initialized = true;
        previousVault = previousVersionVaultAddress;
        initArgs = args;
    }

    function migrate() external override {
        // Mock implementation
    }
}
