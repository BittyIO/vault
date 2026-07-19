// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {IVaultFull} from "../helpers/IVaultFull.sol";
import {AddressZero} from "../../src/interfaces/IBittyV1Vault.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {
    IBittyV1VaultFactory,
    VaultAlreadyActivated,
    NotDeployer,
    EthTransferFailed
} from "../../src/interfaces/IBittyV1VaultFactory.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {IBittyV1Guard, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {
    IAccessControlDefaultAdminRules
} from "openzeppelin-contracts/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

contract BittyV1VaultFactoryTest is Test {
    BittyV1VaultFactory public factory;
    address public vaultImplementation;
    address public defiFacet;
    address public owner1;
    address public owner2;
    address public wethAddress;
    address public wbtcAddress;
    address public usdtAddress;
    address public usdcAddress;
    address public aaveV3Address;
    address public uniswapV4RouterAddress;
    address[] public assetAddresses;
    address[] public stableCoinAddresses;
    address[] public vaultAssetAddresses;
    address[] public lendingProtocols;
    address[] public stakingProtocols;
    address[] public ammProtocols;
    address[] public intentProtocols;
    address public guardAddress;
    address public assetManagerAddress;

    function setUp() public {
        wethAddress = makeAddr("wethAddress");
        guardAddress = address(new BittyV1Guard());
        defiFacet = address(new BittyV1VaultDeFiFacet());

        vaultImplementation = address(new BittyV1Vault());
        factory = new BittyV1VaultFactory();
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        assetManagerAddress = makeAddr("assetManager");
        wbtcAddress = makeAddr("wbtcAddress");
        usdtAddress = makeAddr("usdtAddress");
        usdcAddress = makeAddr("usdcAddress");
        aaveV3Address = makeAddr("aaveV3Address");
        uniswapV4RouterAddress = makeAddr("uniswapV4RouterAddress");
        assetAddresses = new address[](2);
        assetAddresses[0] = wbtcAddress;
        assetAddresses[1] = wethAddress;
        stableCoinAddresses = new address[](2);
        stableCoinAddresses[0] = usdtAddress;
        stableCoinAddresses[1] = usdcAddress;
        lendingProtocols = new address[](0);
        stakingProtocols = new address[](0);
        ammProtocols = new address[](1);
        ammProtocols[0] = uniswapV4RouterAddress;
        intentProtocols = new address[](0);
        vm.startPrank(tx.origin);
        BittyV1Guard wl = BittyV1Guard(guardAddress);
        wl.grantRole(wl.ASSET_MANAGER_ROLE(), tx.origin);
        wl.grantRole(wl.STABLE_COIN_MANAGER_ROLE(), tx.origin);
        wl.grantRole(wl.LENDING_MANAGER_ROLE(), tx.origin);
        wl.grantRole(wl.STAKING_MANAGER_ROLE(), tx.origin);
        wl.grantRole(wl.AMM_MANAGER_ROLE(), tx.origin);
        IBittyV1Guard(guardAddress).addAssets(assetAddresses);
        IBittyV1Guard(guardAddress).addStableCoins(stableCoinAddresses);
        IBittyV1Guard(guardAddress).addLendingProtocols(lendingProtocols);
        IBittyV1Guard(guardAddress).addAMMProtocols(ammProtocols);
        IBittyV1Guard(guardAddress).addStakingProtocols(stakingProtocols);
        vaultAssetAddresses = new address[](4);
        vaultAssetAddresses[0] = wbtcAddress;
        vaultAssetAddresses[1] = wethAddress;
        vaultAssetAddresses[2] = usdtAddress;
        vaultAssetAddresses[3] = usdcAddress;
        vm.stopPrank();
    }

    // Activate `owner`'s single vault and, if given, grant a separate asset manager
    // (asset managers are no longer passed at activation — the owner grants them afterwards).
    function _activateVault(address owner, address assetManager) internal returns (address vault) {
        vm.startPrank(owner);
        factory.activateVault(vaultAssetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);
        vault = factory.vaultAddress(owner);
        if (assetManager != address(0)) {
            BittyV1Vault(payable(vault)).addAssetManager(assetManager, 0, 0, type(uint64).max, 0);
        }
        vm.stopPrank();
    }

    function _newVault() internal returns (address) {
        return _activateVault(tx.origin, assetManagerAddress);
    }

    function _newVaultFor(address owner) internal returns (address) {
        return _activateVault(owner, assetManagerAddress);
    }

    function _initFactory() internal {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, defiFacet, guardAddress, wethAddress);
    }

    function test_activatedVault_hasOneDayDefaultAdminDelay() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_activateVault(owner1, assetManagerAddress)));
        assertEq(vaultInstance.OWNER_TRANSFER_DELAY(), 1 days);
        assertEq(vaultInstance.defaultAdminDelay(), 1 days);
    }

    function test_activatedVault_ownerIsAdminInstantly() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_activateVault(owner1, assetManagerAddress)));

        assertEq(vaultInstance.defaultAdmin(), owner1);
        assertTrue(vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), owner1));
    }

    function test_activatedVault_adminTransferRequiresOneDayDelay() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_activateVault(owner1, assetManagerAddress)));

        vm.prank(owner1);
        vaultInstance.beginDefaultAdminTransfer(owner2);

        (, uint48 schedule) = vaultInstance.pendingDefaultAdmin();

        vm.prank(owner2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        vaultInstance.acceptDefaultAdminTransfer();

        vm.warp(block.timestamp + 1 days - 1);
        vm.prank(owner2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        vaultInstance.acceptDefaultAdminTransfer();
    }

    function test_activatedVault_adminTransferSucceedsAfterOneDay() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_activateVault(owner1, assetManagerAddress)));

        vm.prank(owner1);
        vaultInstance.beginDefaultAdminTransfer(owner2);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(owner2);
        vaultInstance.acceptDefaultAdminTransfer();

        assertEq(vaultInstance.defaultAdmin(), owner2);
        assertTrue(vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), owner2));
        assertFalse(vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), owner1));
    }

    function test_activatedVault_cancelDefaultAdminTransfer() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_activateVault(owner1, assetManagerAddress)));

        vm.startPrank(owner1);
        vaultInstance.beginDefaultAdminTransfer(owner2);
        vaultInstance.cancelDefaultAdminTransfer();
        vm.stopPrank();

        (address pendingAdmin,) = vaultInstance.pendingDefaultAdmin();
        assertEq(pendingAdmin, address(0));

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(owner2);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, owner2)
        );
        vaultInstance.acceptDefaultAdminTransfer();
        assertEq(vaultInstance.defaultAdmin(), owner1);
    }

    function test_factoryRevertsIfAddressZero() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        vm.expectRevert(AddressZero.selector);
        factory.initialize(address(0), defiFacet, guardAddress, wethAddress);

        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        vm.expectRevert(AddressZero.selector);
        factory.initialize(vaultImplementation, defiFacet, address(0), wethAddress);

        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        vm.expectRevert(AddressZero.selector);
        factory.initialize(vaultImplementation, defiFacet, guardAddress, address(0));
    }

    function test_initializeOnlyByDeployer() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker, attacker);
        vm.expectRevert(NotDeployer.selector);
        factory.initialize(vaultImplementation, defiFacet, guardAddress, wethAddress);

        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, defiFacet, guardAddress, wethAddress);
        assertEq(factory.guardAddress(), guardAddress);
    }

    function test_ActivateVaultRevertsIfAddressNotRegistered() public {
        _initFactory();
        address[] memory invalidAddressArray = new address[](1);
        invalidAddressArray[0] = makeAddr("invalidAddress");
        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(invalidAddressArray, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);
    }

    function test_ActivateVaultForDifferentOwners() public {
        _initFactory();
        address vault1 = _newVaultFor(owner1);
        address vault2 = _newVaultFor(owner2);
        assertTrue(vault1 != vault2, "Different owners should get different vault addresses");
        assertTrue(vault1 != address(0), "Vault1 should not be zero address");
        assertTrue(vault2 != address(0), "Vault2 should not be zero address");
    }

    function test_VaultAddress() public {
        _initFactory();
        address computedAddress = factory.vaultAddress(owner1);
        assertTrue(computedAddress != address(0), "Computed address should not be zero");

        address activatedAddress = _newVaultFor(owner1);
        assertTrue(activatedAddress != address(0), "Activated address should not be zero");
        assertEq(computedAddress, activatedAddress, "Computed address should match activation");
    }

    function test_SameOwnerAlreadyActivated() public {
        _initFactory();
        _newVaultFor(owner1);

        vm.prank(owner1);
        vm.expectRevert(VaultAlreadyActivated.selector);
        factory.activateVault(vaultAssetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);
    }

    function test_ActivatedVaultCanBeInitialized() public {
        _initFactory();
        address vaultAddr = _newVault();
        BittyV1Vault vault = BittyV1Vault(payable(vaultAddr));

        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), tx.origin), "Owner should hold DEFAULT_ADMIN_ROLE");

        address[] memory assets = vault.getAssets();
        assertEq(assets[0], wbtcAddress, "WBTC address should be set");
        assertEq(assets[1], wethAddress, "WETH address should be set");
        address[] memory stableCoins = vault.getStableCoins();
        assertEq(stableCoins[0], usdtAddress, "USDT address should be set");
        assertEq(stableCoins[1], usdcAddress, "USDC address should be set");
    }

    function test_ActivateVaultRevertsIfVaultAlreadyExistsAtComputedAddress() public {
        _initFactory();

        bytes32 salt = keccak256(abi.encodePacked(owner1));
        address computedAddr = Clones.predictDeterministicAddress(vaultImplementation, salt, address(factory));

        bytes memory minimalBytecode =
            hex"6080604052348015600f57600080fd5b50603f80601d6000396000f3fe6080604052600080fdfea2646970667358221220";
        address deployedAddr;
        assembly {
            deployedAddr := create2(0, add(minimalBytecode, 0x20), mload(minimalBytecode), salt)
        }

        if (deployedAddr == computedAddr && deployedAddr.code.length > 0) {
            vm.prank(owner1);
            vm.expectRevert(VaultAlreadyActivated.selector);
            factory.activateVault(
                vaultAssetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols
            );
        }
    }

    function test_InitializeSuccess() public {
        _initFactory();
        assertEq(factory.guardAddress(), guardAddress, "BittyV1Guard address should be set");
    }

    function test_ActivateVaultRevertsIfStableCoinNotRegistered() public {
        _initFactory();
        address[] memory invalidStableCoinArray = new address[](1);
        invalidStableCoinArray[0] = makeAddr("invalidStableCoin");
        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(invalidStableCoinArray, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);
    }

    function test_ActivateVaultRevertsIfLendingProtocolNotRegistered() public {
        _initFactory();
        address[] memory invalidLendingProviderArray = new address[](1);
        invalidLendingProviderArray[0] = makeAddr("invalidLendingProtocol");
        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            vaultAssetAddresses, invalidLendingProviderArray, stakingProtocols, ammProtocols, intentProtocols
        );
    }

    function test_ActivateVaultRevertsIfAMMProtocolNotRegistered() public {
        _initFactory();
        address[] memory invalidAMMProviderArray = new address[](1);
        invalidAMMProviderArray[0] = makeAddr("invalidAMMProtocol");
        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            vaultAssetAddresses, lendingProtocols, stakingProtocols, invalidAMMProviderArray, intentProtocols
        );
    }

    function test_ActivateVaultRevertsIfIntentProtocolNotRegistered() public {
        _initFactory();
        address[] memory invalidIntentProviderArray = new address[](1);
        invalidIntentProviderArray[0] = makeAddr("invalidIntentProtocol");
        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            vaultAssetAddresses, lendingProtocols, stakingProtocols, ammProtocols, invalidIntentProviderArray
        );
    }

    function test_ActivateVaultWithIntentProtocols() public {
        _initFactory();
        address intentProtocol = makeAddr("intentProtocol");
        address[] memory selectedIntentProtocols = new address[](1);
        selectedIntentProtocols[0] = intentProtocol;

        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addIntentProtocols(selectedIntentProtocols);

        vm.prank(owner1);
        factory.activateVault(
            vaultAssetAddresses, lendingProtocols, stakingProtocols, ammProtocols, selectedIntentProtocols
        );
        address vault = factory.vaultAddress(owner1);

        assertTrue(vault.code.length > 0, "Vault should be activated");
        address[] memory activatedIntentProtocols = IVaultFull(payable(vault)).getIntentProtocols();
        assertEq(activatedIntentProtocols.length, 1);
        assertEq(activatedIntentProtocols[0], intentProtocol);
    }

    function test_ActivateVaultWithEmptyArrays() public {
        _initFactory();

        vm.prank(owner1);
        factory.activateVault(new address[](0), new address[](0), new address[](0), new address[](0), new address[](0));
        address vault = factory.vaultAddress(owner1);

        assertTrue(vault.code.length > 0, "Vault should be activated");
    }

    function test_ActivateVaultEmitsEvent() public {
        _initFactory();

        vm.expectEmit(true, false, false, true);
        emit BittyV1VaultFactory.VaultActivated(tx.origin);
        address vault = _newVault();

        assertTrue(vault.code.length > 0, "Vault should be activated");

        BittyV1Vault vaultInstance = BittyV1Vault(payable(vault));
        assertTrue(
            vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), tx.origin), "Owner should hold DEFAULT_ADMIN_ROLE"
        );
    }

    function test_VaultAddressForDifferentOwners() public {
        _initFactory();
        address computed1 = factory.vaultAddress(owner1);
        address computed2 = factory.vaultAddress(owner2);

        assertTrue(computed1 != computed2, "Different owners should compute to different addresses");
        assertTrue(computed1 != address(0), "Computed address should not be zero");
        assertTrue(computed2 != address(0), "Computed address should not be zero");
    }

    function test_ActivateVaultWithMultipleAssets() public {
        _initFactory();
        address[] memory multipleAssets = new address[](3);
        multipleAssets[0] = wbtcAddress;
        multipleAssets[1] = wethAddress;
        multipleAssets[2] = makeAddr("asset3");

        address[] memory newAsset = new address[](1);
        newAsset[0] = multipleAssets[2];
        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addAssets(newAsset);

        vm.prank(owner1);
        factory.activateVault(multipleAssets, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);

        assertTrue(factory.vaultAddress(owner1).code.length > 0, "Vault should be activated");
    }

    function test_ActivateVaultWithMultipleStableCoins() public {
        _initFactory();
        address[] memory multipleStableCoins = new address[](3);
        multipleStableCoins[0] = usdtAddress;
        multipleStableCoins[1] = usdcAddress;
        multipleStableCoins[2] = makeAddr("stableCoin3");

        address[] memory newStableCoin = new address[](1);
        newStableCoin[0] = multipleStableCoins[2];
        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addStableCoins(newStableCoin);

        address[] memory activationAssets = new address[](assetAddresses.length + multipleStableCoins.length);
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            activationAssets[i] = assetAddresses[i];
        }
        for (uint256 i = 0; i < multipleStableCoins.length; i++) {
            activationAssets[assetAddresses.length + i] = multipleStableCoins[i];
        }

        vm.prank(owner1);
        factory.activateVault(activationAssets, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);

        assertTrue(factory.vaultAddress(owner1).code.length > 0, "Vault should be activated");
    }

    function test_ActivateVaultWithMultipleLendingProtocols() public {
        _initFactory();
        address LendingProtocol1 = makeAddr("LendingProtocol1");
        address LendingProtocol2 = makeAddr("LendingProtocol2");
        address[] memory multipleLendingProtocols = new address[](2);
        multipleLendingProtocols[0] = LendingProtocol1;
        multipleLendingProtocols[1] = LendingProtocol2;

        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addLendingProtocols(multipleLendingProtocols);

        address vault = _newVaultFor(owner1);

        assertTrue(vault.code.length > 0, "Vault should be activated");
    }

    function test_ActivateVaultWithMultipleAMMProtocols() public {
        _initFactory();
        address swapProtocol1 = makeAddr("swapProtocol1");
        address swapProtocol2 = makeAddr("swapProtocol2");
        address[] memory multipleAMMProtocols = new address[](2);
        multipleAMMProtocols[0] = swapProtocol1;
        multipleAMMProtocols[1] = swapProtocol2;

        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addAMMProtocols(multipleAMMProtocols);

        vm.prank(owner1);
        factory.activateVault(
            vaultAssetAddresses, lendingProtocols, stakingProtocols, multipleAMMProtocols, intentProtocols
        );

        assertTrue(factory.vaultAddress(owner1).code.length > 0, "Vault should be activated");
    }

    function test_ActivateVaultRevertsIfMultipleAssetsOneNotRegistered() public {
        _initFactory();
        address[] memory mixedAssets = new address[](3);
        mixedAssets[0] = wbtcAddress;
        mixedAssets[1] = wethAddress;
        mixedAssets[2] = makeAddr("invalidAsset");

        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(mixedAssets, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);
    }

    function test_ActivateVaultRevertsIfMultipleStableCoinsOneNotRegistered() public {
        _initFactory();
        address[] memory mixedStableCoins = new address[](3);
        mixedStableCoins[0] = usdtAddress;
        mixedStableCoins[1] = usdcAddress;
        mixedStableCoins[2] = makeAddr("invalidStableCoin");

        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(mixedStableCoins, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);
    }

    function test_ActivateVaultRevertsIfMultipleLendingProtocolsOneNotRegistered() public {
        _initFactory();
        address LendingProtocol1 = makeAddr("LendingProtocol1");
        address[] memory mixedLendingProtocols = new address[](2);
        mixedLendingProtocols[0] = LendingProtocol1;
        mixedLendingProtocols[1] = makeAddr("invalidLendingProtocol");

        address[] memory validProtocol = new address[](1);
        validProtocol[0] = LendingProtocol1;
        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addLendingProtocols(validProtocol);

        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            vaultAssetAddresses, mixedLendingProtocols, stakingProtocols, ammProtocols, intentProtocols
        );
    }

    function test_ActivateVaultRevertsIfMultipleAMMProtocolsOneNotRegistered() public {
        _initFactory();
        address swapProtocol1 = makeAddr("swapProtocol1");
        address[] memory mixedAMMProtocols = new address[](2);
        mixedAMMProtocols[0] = swapProtocol1;
        mixedAMMProtocols[1] = makeAddr("invalidAMMProtocol");

        address[] memory validProtocol = new address[](1);
        validProtocol[0] = swapProtocol1;
        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addAMMProtocols(validProtocol);

        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            vaultAssetAddresses, lendingProtocols, stakingProtocols, mixedAMMProtocols, intentProtocols
        );
    }

    function test_ActivateVaultRevertsIfVaultAlreadyExistsAtComputedAddressForced() public {
        _initFactory();

        bytes32 salt = keccak256(abi.encodePacked(owner1));
        address computedAddr = Clones.predictDeterministicAddress(vaultImplementation, salt, address(factory));

        bytes memory minimalBytecode =
            hex"6080604052348015600f57600080fd5b50603f80601d6000396000f3fe6080604052600080fdfea2646970667358221220";

        address deployedAddr;
        assembly {
            deployedAddr := create2(0, add(minimalBytecode, 0x20), mload(minimalBytecode), salt)
        }

        if (deployedAddr == computedAddr && deployedAddr.code.length > 0) {
            vm.prank(owner1);
            vm.expectRevert(VaultAlreadyActivated.selector);
            factory.activateVault(
                vaultAssetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols
            );
        } else {
            vm.etch(computedAddr, minimalBytecode);
            if (computedAddr.code.length > 0) {
                vm.prank(owner1);
                vm.expectRevert(VaultAlreadyActivated.selector);
                factory.activateVault(
                    vaultAssetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols
                );
            }
        }
    }

    function test_VaultAddressIsDeterministic() public {
        _initFactory();

        address addr1 = factory.vaultAddress(owner1);
        address addr2 = factory.vaultAddress(owner2);

        assertTrue(addr1 != address(0), "Computed address should not be zero");
        assertTrue(addr2 != address(0), "Computed address should not be zero");
        assertTrue(addr1 != addr2, "Different owners should produce different addresses");

        address addr1Again = factory.vaultAddress(owner1);
        assertEq(addr1, addr1Again, "Same owner should produce same computed address");
    }

    function test_ActivateVaultSuccessWithAllValidParameters() public {
        _initFactory();

        address vault = _newVault();

        assertTrue(vault.code.length > 0, "Vault should be activated");
        BittyV1Vault vaultInstance = BittyV1Vault(payable(vault));
        assertTrue(
            vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), tx.origin), "Owner should hold DEFAULT_ADMIN_ROLE"
        );
    }

    function test_InitializeSetsStateVariables() public {
        _initFactory();
        assertEq(factory.guardAddress(), guardAddress, "BittyV1Guard address should be set");
    }

    function test_Factory_initCode() public {
        bytes memory bytecode = type(BittyV1VaultFactory).creationCode;
        console.logBytes32(keccak256(bytecode));
    }

    function test_ActivateVaultFor_setsOwner() public {
        _initFactory();
        address vault = _newVaultFor(owner1);
        assertTrue(BittyV1Vault(payable(vault)).hasRole(BittyV1Vault(payable(vault)).DEFAULT_ADMIN_ROLE(), owner1));
    }

    function test_ActivateVault_ownerIsAlwaysCaller() public {
        _initFactory();
        // The owner is the caller and cannot be specified: an attacker activating their
        // vault gets their own address, which cannot occupy the victim's deterministic
        // address, so the pre-activation asset-manager-injection vector is structurally
        // impossible.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        factory.activateVault(new address[](0), new address[](0), new address[](0), new address[](0), new address[](0));
        address attackerVault = factory.vaultAddress(attacker);

        address victimVault = _activateVault(owner1, assetManagerAddress);
        assertTrue(attackerVault != victimVault, "attacker cannot occupy victim's vault address");

        BittyV1Vault av = BittyV1Vault(payable(attackerVault));
        assertTrue(av.hasRole(av.DEFAULT_ADMIN_ROLE(), attacker), "caller is owner");
        assertFalse(av.hasRole(av.DEFAULT_ADMIN_ROLE(), owner1), "victim is not owner");
    }

    function test_ActivateVaultFor_revertVaultAlreadyActivated() public {
        _initFactory();
        _newVaultFor(owner1);
        vm.prank(owner1);
        vm.expectRevert(VaultAlreadyActivated.selector);
        factory.activateVault(vaultAssetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);
    }

    function test_ActivateVaultFor_emitsVaultActivatedEvent() public {
        _initFactory();
        address expectedVault = factory.vaultAddress(owner1);

        vm.expectEmit(true, false, false, true);
        emit BittyV1VaultFactory.VaultActivated(owner1);

        vm.prank(owner1);
        factory.activateVault(vaultAssetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);
        assertTrue(expectedVault.code.length > 0);
    }

    function test_ActivateVaultFor_initializesVaultConfig() public {
        _initFactory();
        BittyV1Vault vault = BittyV1Vault(payable(_newVaultFor(owner1)));

        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), owner1));
        assertEq(vault.getAssets()[0], wbtcAddress);
        assertEq(vault.getAssets()[1], wethAddress);
        assertEq(vault.getStableCoins()[0], usdtAddress);
        assertEq(vault.getStableCoins()[1], usdcAddress);
    }

    function test_ActivatedVault_ownerGrantsAssetManager() public {
        _initFactory();
        BittyV1Vault vault = BittyV1Vault(payable(_newVaultFor(owner1)));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), owner1));
        assertTrue(vault.hasRole(vault.ASSET_MANAGER_ROLE(), assetManagerAddress));
    }

    function test_ActivatedVault_ownerGrantsMultipleAssetManagers() public {
        _initFactory();
        address manager1 = makeAddr("manager1");
        address manager2 = makeAddr("manager2");

        vm.startPrank(owner1);
        factory.activateVault(vaultAssetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);
        BittyV1Vault vaultInstance = BittyV1Vault(payable(factory.vaultAddress(owner1)));
        vaultInstance.addAssetManager(manager1, 0, 0, type(uint64).max, 0);
        vaultInstance.addAssetManager(manager2, 0, 0, type(uint64).max, 0);
        vm.stopPrank();

        assertTrue(vaultInstance.hasRole(vaultInstance.ASSET_MANAGER_ROLE(), manager1));
        assertTrue(vaultInstance.hasRole(vaultInstance.ASSET_MANAGER_ROLE(), manager2));
    }

    function test_ActivateVaultFor_nonOwnerCannotGrantRoles() public {
        _initFactory();
        BittyV1Vault vault = BittyV1Vault(payable(_newVaultFor(owner1)));

        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(owner2);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        vault.grantRole(adminRole, owner2);
    }

    function test_ActivateVault_withTxOriginOwner() public {
        _initFactory();
        address expected = factory.vaultAddress(tx.origin);
        address vault = _newVault();
        assertEq(vault, expected);
        assertTrue(BittyV1Vault(payable(vault)).hasRole(BittyV1Vault(payable(vault)).DEFAULT_ADMIN_ROLE(), tx.origin));
        assertTrue(
            BittyV1Vault(payable(vault)).hasRole(BittyV1Vault(payable(vault)).ASSET_MANAGER_ROLE(), assetManagerAddress)
        );
    }

    function test_ActivateVault_multisigOwnerAddress() public {
        _initFactory();
        address multisigOwner = makeAddr("gnosisSafe");
        address vault = _activateVault(multisigOwner, assetManagerAddress);

        assertEq(factory.vaultAddress(multisigOwner), vault);
        assertTrue(
            BittyV1Vault(payable(vault)).hasRole(BittyV1Vault(payable(vault)).DEFAULT_ADMIN_ROLE(), multisigOwner)
        );

        bytes32 adminRole = BittyV1Vault(payable(vault)).DEFAULT_ADMIN_ROLE();
        vm.prank(owner1);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        BittyV1Vault(payable(vault)).grantRole(adminRole, makeAddr("other"));
    }

    // ============ One vault per owner ============

    function test_differentOwnersProduceDifferentVaults() public {
        _initFactory();
        address vault1 = _activateVault(owner1, assetManagerAddress);
        address vault2 = _activateVault(owner2, assetManagerAddress);

        assertTrue(vault1 != vault2);
        assertTrue(BittyV1Vault(payable(vault1)).hasRole(BittyV1Vault(payable(vault1)).DEFAULT_ADMIN_ROLE(), owner1));
        assertTrue(BittyV1Vault(payable(vault2)).hasRole(BittyV1Vault(payable(vault2)).DEFAULT_ADMIN_ROLE(), owner2));
    }

    function test_secondActivationSameOwnerReverts() public {
        _initFactory();
        _activateVault(owner1, assetManagerAddress);

        vm.prank(owner1);
        vm.expectRevert(VaultAlreadyActivated.selector);
        factory.activateVault(new address[](0), new address[](0), new address[](0), new address[](0), new address[](0));
    }

    function test_vaultAddressMatchesActivation() public {
        _initFactory();
        address predicted = factory.vaultAddress(owner1);
        address actual = _activateVault(owner1, assetManagerAddress);
        assertEq(predicted, actual);
    }
}

contract ActivateVaultWithAssetsTest is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    BittyV1VaultFactory internal factory;
    BittyV1Guard internal guard;
    WETH internal weth;
    MockERC20 internal wbtc;
    MockERC20 internal usdc;

    address internal user;
    uint256 internal userPk;
    uint256 internal deadline;

    address[] internal noProtocols;

    function setUp() public {
        weth = new WETH();
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        guard = new BittyV1Guard();
        vm.startPrank(tx.origin);
        guard.grantRole(guard.ASSET_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.STABLE_COIN_MANAGER_ROLE(), tx.origin);
        guard.addAssets(_assets(address(weth), address(wbtc)));
        guard.addStableCoins(_single(address(usdc)));
        vm.stopPrank();

        address vaultImpl = address(new BittyV1Vault());
        address defiFacet = address(new BittyV1VaultDeFiFacet());
        factory = new BittyV1VaultFactory();
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImpl, defiFacet, address(guard), address(weth));

        (user, userPk) = makeAddrAndKey("user");
        deadline = block.timestamp + 1 hours;
    }

    function _single(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _assets(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _signPermit(MockERC20 token, address owner, uint256 ownerPk, address spender, uint256 value)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, token.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerPk, digest);
    }

    // A deposit funded via a signed EIP-2612 permit (no prior approval needed).
    function _permit(MockERC20 token, uint256 amount) internal view returns (IBittyV1VaultFactory.AssetInput memory) {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(token, user, userPk, address(factory), amount);
        return IBittyV1VaultFactory.AssetInput({
            asset: address(token), amount: amount, usePermit: true, deadline: deadline, v: v, r: r, s: s
        });
    }

    // A deposit funded via a prior approval (for tokens that don't support permit).
    function _approved(MockERC20 token, uint256 amount) internal pure returns (IBittyV1VaultFactory.AssetInput memory) {
        return IBittyV1VaultFactory.AssetInput({
            asset: address(token), amount: amount, usePermit: false, deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)
        });
    }

    function _deposits(IBittyV1VaultFactory.AssetInput memory a)
        internal
        pure
        returns (IBittyV1VaultFactory.AssetInput[] memory arr)
    {
        arr = new IBittyV1VaultFactory.AssetInput[](1);
        arr[0] = a;
    }

    function _noDeposits() internal pure returns (IBittyV1VaultFactory.AssetInput[] memory arr) {
        arr = new IBittyV1VaultFactory.AssetInput[](0);
    }

    function test_permitPathPullsErc20() public {
        uint256 amount = 3e8;
        wbtc.mint(user, amount);
        address vault = factory.vaultAddress(user);
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(_permit(wbtc, amount));

        vm.prank(user);
        factory.activateVaultWithAssets(
            _single(address(wbtc)), deposits, noProtocols, noProtocols, noProtocols, noProtocols
        );

        assertEq(wbtc.balanceOf(vault), amount, "vault received WBTC via permit");
        assertEq(wbtc.balanceOf(user), 0, "user WBTC drained");
        assertTrue(
            BittyV1Vault(payable(vault)).hasRole(BittyV1Vault(payable(vault)).DEFAULT_ADMIN_ROLE(), user),
            "user owns vault"
        );
        assertEq(BittyV1Vault(payable(vault)).getAssets()[0], address(wbtc), "WBTC configured");
    }

    function test_approvedPathPullsErc20() public {
        uint256 amount = 2e8;
        wbtc.mint(user, amount);
        address vault = factory.vaultAddress(user);
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(_approved(wbtc, amount));

        vm.startPrank(user);
        wbtc.approve(address(factory), amount);
        factory.activateVaultWithAssets(
            _single(address(wbtc)), deposits, noProtocols, noProtocols, noProtocols, noProtocols
        );
        vm.stopPrank();

        assertEq(wbtc.balanceOf(vault), amount, "vault received WBTC via approval");
    }

    function test_mixedPermitAndApproved() public {
        uint256 wbtcAmount = 2e8;
        uint256 usdcAmount = 1_000e6;
        wbtc.mint(user, wbtcAmount);
        usdc.mint(user, usdcAmount);
        address vault = factory.vaultAddress(user);

        IBittyV1VaultFactory.AssetInput[] memory deposits = new IBittyV1VaultFactory.AssetInput[](2);
        deposits[0] = _approved(wbtc, wbtcAmount); // pre-approved transfer
        deposits[1] = _permit(usdc, usdcAmount); // signed permit

        vm.startPrank(user);
        wbtc.approve(address(factory), wbtcAmount);
        factory.activateVaultWithAssets(
            _assets(address(wbtc), address(usdc)), deposits, noProtocols, noProtocols, noProtocols, noProtocols
        );
        vm.stopPrank();

        assertEq(wbtc.balanceOf(vault), wbtcAmount, "vault received WBTC");
        assertEq(usdc.balanceOf(vault), usdcAmount, "vault received USDC");
    }

    function test_assetsPlusEth() public {
        uint256 wbtcAmount = 1e8;
        uint256 ethAmount = 0.5 ether;
        wbtc.mint(user, wbtcAmount);
        vm.deal(user, ethAmount);
        address vault = factory.vaultAddress(user);
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(_permit(wbtc, wbtcAmount));

        vm.prank(user);
        factory.activateVaultWithAssets{value: ethAmount}(
            _assets(address(wbtc), address(weth)), deposits, noProtocols, noProtocols, noProtocols, noProtocols
        );

        assertEq(wbtc.balanceOf(vault), wbtcAmount, "vault received WBTC");
        assertEq(weth.balanceOf(vault), ethAmount, "vault received wrapped ETH");
        assertEq(vault.balance, 0, "no raw ETH left in vault");
    }

    function test_ethOnlyNoDeposits() public {
        uint256 ethAmount = 1 ether;
        vm.deal(user, ethAmount);
        address vault = factory.vaultAddress(user);

        vm.prank(user);
        factory.activateVaultWithAssets{value: ethAmount}(
            _single(address(weth)), _noDeposits(), noProtocols, noProtocols, noProtocols, noProtocols
        );

        assertEq(weth.balanceOf(vault), ethAmount, "vault holds wrapped WETH");
    }

    function test_toleratesFrontRunConsumedPermit() public {
        uint256 amount = 1e8;
        wbtc.mint(user, amount);
        address vault = factory.vaultAddress(user);
        IBittyV1VaultFactory.AssetInput memory d = _permit(wbtc, amount);
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(d);

        // Attacker front-runs by submitting the signed permit directly, consuming the nonce and
        // setting the allowance. The factory's own permit call then reverts but is tolerated.
        wbtc.permit(user, address(factory), amount, deadline, d.v, d.r, d.s);

        vm.prank(user);
        factory.activateVaultWithAssets(
            _single(address(wbtc)), deposits, noProtocols, noProtocols, noProtocols, noProtocols
        );

        assertEq(wbtc.balanceOf(vault), amount, "transfer still succeeds via pre-set allowance");
    }

    function test_revertsWhenAssetNotRegistered() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(user, 1e18);
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(_permit(stray, 1e18));

        vm.prank(user);
        vm.expectRevert(NotRegistered.selector);
        factory.activateVaultWithAssets(
            _single(address(stray)), deposits, noProtocols, noProtocols, noProtocols, noProtocols
        );
    }

    function test_revertsWhenPermitInvalidAndNoAllowance() public {
        uint256 amount = 1e8;
        wbtc.mint(user, amount);
        IBittyV1VaultFactory.AssetInput memory d = _permit(wbtc, amount);
        d.s = bytes32(uint256(d.s) ^ 1); // corrupt the signature
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(d);

        vm.prank(user);
        vm.expectRevert();
        factory.activateVaultWithAssets(
            _single(address(wbtc)), deposits, noProtocols, noProtocols, noProtocols, noProtocols
        );
    }

    function test_revertsWhenApprovedPathNotApproved() public {
        uint256 amount = 1e8;
        wbtc.mint(user, amount);
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(_approved(wbtc, amount));

        vm.prank(user);
        vm.expectRevert();
        factory.activateVaultWithAssets(
            _single(address(wbtc)), deposits, noProtocols, noProtocols, noProtocols, noProtocols
        );
    }

    function test_revertsWhenAlreadyActivated() public {
        uint256 amount = 1e8;
        wbtc.mint(user, amount);
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(_permit(wbtc, amount));

        vm.startPrank(user);
        factory.activateVault(_single(address(wbtc)), noProtocols, noProtocols, noProtocols, noProtocols);

        vm.expectRevert(VaultAlreadyActivated.selector);
        factory.activateVaultWithAssets(
            _single(address(wbtc)), deposits, noProtocols, noProtocols, noProtocols, noProtocols
        );
        vm.stopPrank();
    }

    function test_emitsVaultActivated() public {
        uint256 amount = 1e8;
        wbtc.mint(user, amount);
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(_permit(wbtc, amount));

        vm.prank(user);
        vm.expectEmit(true, false, false, true);
        emit BittyV1VaultFactory.VaultActivated(user);
        factory.activateVaultWithAssets(
            _single(address(wbtc)), deposits, noProtocols, noProtocols, noProtocols, noProtocols
        );
    }

    function test_revertsWhenEthForwardFails() public {
        // A factory whose configured WETH reverts on deposit makes the vault's receive() revert while
        // wrapping the forwarded ETH, which the factory surfaces as EthTransferFailed.
        RevertingWeth badWeth = new RevertingWeth();
        BittyV1VaultFactory badFactory = new BittyV1VaultFactory();
        address vaultImpl = address(new BittyV1Vault());
        address defiFacet = address(new BittyV1VaultDeFiFacet());
        vm.prank(badFactory.DEPLOYER(), badFactory.DEPLOYER());
        badFactory.initialize(vaultImpl, defiFacet, address(guard), address(badWeth));

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(EthTransferFailed.selector);
        badFactory.activateVaultWithAssets{value: 1 ether}(
            new address[](0), _noDeposits(), noProtocols, noProtocols, noProtocols, noProtocols
        );
    }
}

contract RevertingWeth {
    function deposit() external payable {
        revert("no deposit");
    }
}
