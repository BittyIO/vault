// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import "forge-std/console.sol";
import {vaultProtocols} from "../helpers/VaultSets.sol";
import {guardAddAssets, guardAddStableCoins, guardAddProtocols} from "../helpers/GuardRegister.sol";
import {GUARD_DEPLOYER} from "../helpers/GuardDeployer.sol";
import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {IVaultFull} from "../helpers/IVaultFull.sol";
import {MockIntentProtocol} from "../helpers/MockIntentProtocol.sol";
import {MockSettlement} from "../helpers/MockSettlement.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {AddressZero, OwnershipNotTransferable, NoRescueTarget, AutoYield} from "../../src/interfaces/IBittyV1Vault.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {VaultAlreadyActivated, NotDeployer} from "../../src/interfaces/IBittyV1VaultFactory.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {MockCategoryProtocol} from "../helpers/MockCategoryProtocol.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {effectiveAssetManager} from "../helpers/AssetManagerView.sol";

contract BittyV1VaultFactoryTest is Test {
    /// The address that will actually be msg.sender for the next call, honouring an active prank.
    function _self() internal view returns (address) {
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        return mode == VmSafe.CallerMode.None ? address(this) : sender;
    }

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
    AutoYield[] internal noYield;
    address public guardAddress;
    address public assetManagerAddress;

    function setUp() public {
        wethAddress = makeAddr("wethAddress");
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        deployCodeTo("BittyV1Guard.sol:BittyV1Guard", BITTY_GUARD);
        vm.stopPrank();
        guardAddress = BITTY_GUARD;
        defiFacet = address(new BittyV1VaultDeFiFacet());

        vaultImplementation = address(new BittyV1Vault(address(new BittyV1VaultDeFiFacet()), address(0xA07E1D)));
        factory = new BittyV1VaultFactory();
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        assetManagerAddress = makeAddr("assetManager");
        wbtcAddress = makeAddr("wbtcAddress");
        usdtAddress = makeAddr("usdtAddress");
        usdcAddress = makeAddr("usdcAddress");
        aaveV3Address = makeAddr("aaveV3Address");
        // Registered as an AMM protocol below, so it must DECLARE that category — the guard
        // verifies the claim via ERC-165 and rejects a code-less address.
        uniswapV4RouterAddress = address(new MockCategoryProtocol(0x932722bd));
        vm.label(uniswapV4RouterAddress, "uniswapV4RouterAddress");
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
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        BittyV1Guard wl = BittyV1Guard(guardAddress);
        wl.grantRole(wl.ASSET_MANAGER_ROLE(), tx.origin);
        wl.grantRole(wl.PROTOCOL_MANAGER_ROLE(), tx.origin);
        guardAddAssets(address(IBittyV1Guard(guardAddress)), assetAddresses);
        guardAddStableCoins(address(IBittyV1Guard(guardAddress)), stableCoinAddresses);
        guardAddProtocols(address(IBittyV1Guard(guardAddress)), lendingProtocols);
        guardAddProtocols(address(IBittyV1Guard(guardAddress)), ammProtocols);
        guardAddProtocols(address(IBittyV1Guard(guardAddress)), stakingProtocols);
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
        factory.activateVault();
        vault = factory.vaultAddress(owner);
        // Activation no longer takes assets or protocols, so register them the way production does:
        // lazily, by the owner, after the vault exists.
        address[] memory none = new address[](0);
        if (vaultAssetAddresses.length > 0) BittyV1Vault(payable(vault)).updateAssets(vaultAssetAddresses, none);
        if (lendingProtocols.length > 0) BittyV1Vault(payable(vault)).updateProtocols(lendingProtocols, none);
        if (stakingProtocols.length > 0) BittyV1Vault(payable(vault)).updateProtocols(stakingProtocols, none);
        if (ammProtocols.length > 0) BittyV1Vault(payable(vault)).updateProtocols(ammProtocols, none);
        if (intentProtocols.length > 0) BittyV1Vault(payable(vault)).updateProtocols(intentProtocols, none);
        if (assetManager != address(0)) {
            BittyV1Vault(payable(vault)).setAssetManager(assetManager, 0);
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
        factory.initialize(vaultImplementation, wethAddress);
    }

    function _oneAddr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function test_activatedVault_ownerIsAdminInstantly() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_activateVault(owner1, assetManagerAddress)));

        assertEq(vaultInstance.owner(), owner1);
        assertTrue(vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), owner1));
    }

    function test_activatedVault_ownershipNotTransferable() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_activateVault(owner1, assetManagerAddress)));
        bytes32 adminRole = vaultInstance.DEFAULT_ADMIN_ROLE();

        vm.prank(owner1);
        vm.expectRevert(OwnershipNotTransferable.selector);
        vaultInstance.grantRole(adminRole, owner2);

        assertEq(vaultInstance.owner(), owner1);
    }

    function test_activatedVault_delayedRenounceDisabled() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_activateVault(owner1, assetManagerAddress)));
        bytes32 adminRole = vaultInstance.DEFAULT_ADMIN_ROLE();

        // Renounce is only via renounceVaultOwnership(); renounceRole is disabled.
        vm.prank(owner1);
        vm.expectRevert(OwnershipNotTransferable.selector);
        vaultInstance.renounceRole(adminRole, owner1);

        assertEq(vaultInstance.owner(), owner1);
        assertTrue(vaultInstance.hasRole(adminRole, owner1));
    }

    function test_activatedVault_renounceVaultOwnershipRequiresRescue() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_activateVault(owner1, assetManagerAddress)));

        // With no locked immutable scheduled payment to keep paying a safe
        // address, renounce would strand the funds, so it reverts and the vault
        // stays owned.
        vm.prank(owner1);
        vm.expectRevert(NoRescueTarget.selector);
        vaultInstance.renounceVaultOwnership(1);
        assertEq(vaultInstance.owner(), owner1);
    }

    function test_factoryRevertsIfAddressZero() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        vm.expectRevert(AddressZero.selector);
        factory.initialize(address(0), wethAddress);

        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        vm.expectRevert(AddressZero.selector);
        factory.initialize(vaultImplementation, address(0));
    }

    function test_initializeOnlyByDeployer() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker, attacker);
        vm.expectRevert(NotDeployer.selector);
        factory.initialize(vaultImplementation, wethAddress);

        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, wethAddress);
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
        factory.activateVault();
    }

    function test_ActivatedVaultCanBeInitialized() public {
        _initFactory();
        address vaultAddr = _newVault();
        BittyV1Vault vault = BittyV1Vault(payable(vaultAddr));

        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), tx.origin), "Owner should hold DEFAULT_ADMIN_ROLE");

        // Membership, not position: activation seeds WETH and the guard's stable coins before the
        // caller's own list is applied, so the order these arrive in is not part of the contract.
        assertTrue(vault.isAssetAllowed(wbtcAddress), "WBTC address should be set");
        assertTrue(vault.isAssetAllowed(wethAddress), "WETH address should be set");
        assertTrue(vault.isStableCoinAllowed(usdtAddress), "USDT address should be set");
        assertTrue(vault.isStableCoinAllowed(usdcAddress), "USDC address should be set");
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
            factory.activateVault();
        }
    }

    function test_InitializeSuccess() public {
        _initFactory();
    }

    function test_ActivateVaultWithIntentProtocols() public {
        _initFactory();
        address intentProtocol = address(new MockCategoryProtocol(0x1626ba7e));
        address[] memory selectedIntentProtocols = new address[](1);
        selectedIntentProtocols[0] = intentProtocol;

        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(IBittyV1Guard(guardAddress)), selectedIntentProtocols);
        vm.stopPrank();

        vm.prank(owner1);
        factory.activateVault();
        address vault = factory.vaultAddress(owner1);
        // Protocols are no longer an activation parameter — the owner enables them afterwards.
        vm.prank(owner1);
        IVaultFull(payable(vault)).updateProtocols(selectedIntentProtocols, new address[](0));

        assertTrue(vault.code.length > 0, "Vault should be activated");
        address[] memory activatedIntentProtocols = vaultProtocols(guardAddress, vault);
        assertEq(activatedIntentProtocols.length, 1);
        assertEq(activatedIntentProtocols[0], intentProtocol);
    }

    // Gasless off-chain orders validate through the intent protocol's per-vault clone (owner == vault).
    // With no on-chain trade call left to lazily clone it, registration must create the clone, or every
    // CoW order fails as InvalidEip1271Signature. Guards the offchain-migration regression.
    function test_IntentProtocolIsClonedAtRegistration() public {
        _initFactory();
        address intentProtocol = address(new MockIntentProtocol());
        address[] memory selectedIntentProtocols = new address[](1);
        selectedIntentProtocols[0] = intentProtocol;

        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(IBittyV1Guard(guardAddress)), selectedIntentProtocols);
        vm.stopPrank();

        vm.prank(owner1);
        factory.activateVault();
        address vault = factory.vaultAddress(owner1);
        // Protocols are no longer an activation parameter — the owner enables them afterwards.
        vm.prank(owner1);
        IVaultFull(payable(vault)).updateProtocols(selectedIntentProtocols, new address[](0));

        address clone = BittyV1VaultDeFiFacet(payable(vault)).getClone(intentProtocol);
        assertTrue(clone != address(0), "intent protocol must be cloned at registration");
        assertTrue(clone != intentProtocol, "clone must be a distinct per-vault instance");
        assertEq(MockIntentProtocol(clone).owner(), vault, "clone owner must be the vault");
    }

    // CoW can't soft-cancel a vault (eip1271) order, so cancellation is an owner-only on-chain
    // invalidateOrder on the intent protocol's settlement — batched for a TWAP's parts.
    function test_CancelIntentOrdersInvalidatesOnSettlement() public {
        _initFactory();
        MockSettlement settlement = new MockSettlement();
        MockIntentProtocol intent = new MockIntentProtocol();
        intent.setEndpoints(address(settlement), makeAddr("relayer"));
        address intentProtocol = address(intent);
        address[] memory sel = new address[](1);
        sel[0] = intentProtocol;

        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(IBittyV1Guard(guardAddress)), sel);
        vm.stopPrank();

        vm.prank(owner1);
        factory.activateVault();
        address vault = factory.vaultAddress(owner1);
        // Protocols are no longer an activation parameter — the owner enables them afterwards.
        vm.prank(owner1);
        IVaultFull(payable(vault)).updateProtocols(sel, new address[](0));

        bytes[] memory uids = new bytes[](2);
        uids[0] = abi.encodePacked(keccak256("part-0"), vault, uint32(111));
        uids[1] = abi.encodePacked(keccak256("part-1"), vault, uint32(222));

        vm.prank(owner1);
        IVaultFull(payable(vault)).cancelIntentOrders(intentProtocol, uids);
        assertEq(settlement.invalidatedCount(), 2, "both parts invalidated on the settlement");
        assertEq(settlement.invalidated(0), uids[0]);
        assertEq(settlement.invalidated(1), uids[1]);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        IVaultFull(payable(vault)).cancelIntentOrders(intentProtocol, uids);
    }

    function test_CancelIntentOrderScalarInvalidatesOnSettlement() public {
        _initFactory();
        MockSettlement settlement = new MockSettlement();
        MockIntentProtocol intent = new MockIntentProtocol();
        intent.setEndpoints(address(settlement), makeAddr("relayer"));
        address intentProtocol = address(intent);
        address[] memory sel = new address[](1);
        sel[0] = intentProtocol;

        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(IBittyV1Guard(guardAddress)), sel);
        vm.stopPrank();

        vm.prank(owner1);
        factory.activateVault();
        address vault = factory.vaultAddress(owner1);
        vm.prank(owner1);
        IVaultFull(payable(vault)).updateProtocols(sel, new address[](0));

        bytes memory uid = abi.encodePacked(keccak256("single"), vault, uint32(7));

        vm.prank(owner1);
        IVaultFull(payable(vault)).cancelIntentOrder(intentProtocol, uid);
        assertEq(settlement.invalidatedCount(), 1, "the one order is invalidated");
        assertEq(settlement.invalidated(0), uid);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        IVaultFull(payable(vault)).cancelIntentOrder(intentProtocol, uid);
    }

    function test_ActivateVaultWithEmptyArrays() public {
        _initFactory();

        vm.prank(owner1);
        factory.activateVault();
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
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddAssets(address(IBittyV1Guard(guardAddress)), newAsset);

        vm.prank(owner1);
        factory.activateVault();

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
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddStableCoins(address(IBittyV1Guard(guardAddress)), newStableCoin);

        address[] memory activationAssets = new address[](assetAddresses.length + multipleStableCoins.length);
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            activationAssets[i] = assetAddresses[i];
        }
        for (uint256 i = 0; i < multipleStableCoins.length; i++) {
            activationAssets[assetAddresses.length + i] = multipleStableCoins[i];
        }

        vm.prank(owner1);
        factory.activateVault();

        assertTrue(factory.vaultAddress(owner1).code.length > 0, "Vault should be activated");
    }

    function test_ActivateVaultWithMultipleLendingProtocols() public {
        _initFactory();
        address LendingProtocol1 = address(new MockCategoryProtocol(0xb9f16a0c));
        address LendingProtocol2 = address(new MockCategoryProtocol(0xb9f16a0c));
        address[] memory multipleLendingProtocols = new address[](2);
        multipleLendingProtocols[0] = LendingProtocol1;
        multipleLendingProtocols[1] = LendingProtocol2;

        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(IBittyV1Guard(guardAddress)), multipleLendingProtocols);
        vm.stopPrank();

        address vault = _newVaultFor(owner1);

        assertTrue(vault.code.length > 0, "Vault should be activated");
    }

    function test_ActivateVaultWithMultipleAMMProtocols() public {
        _initFactory();
        address swapProtocol1 = address(new MockCategoryProtocol(0x932722bd));
        address swapProtocol2 = address(new MockCategoryProtocol(0x932722bd));
        address[] memory multipleAMMProtocols = new address[](2);
        multipleAMMProtocols[0] = swapProtocol1;
        multipleAMMProtocols[1] = swapProtocol2;

        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(IBittyV1Guard(guardAddress)), multipleAMMProtocols);
        vm.stopPrank();

        vm.prank(owner1);
        factory.activateVault();

        assertTrue(factory.vaultAddress(owner1).code.length > 0, "Vault should be activated");
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
            factory.activateVault();
        } else {
            vm.etch(computedAddr, minimalBytecode);
            if (computedAddr.code.length > 0) {
                vm.prank(owner1);
                vm.expectRevert(VaultAlreadyActivated.selector);
                factory.activateVault();
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
        // address, so the pre-activation asset manager-injection vector is structurally
        // impossible.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        factory.activateVault();
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
        factory.activateVault();
    }

    function test_ActivateVaultFor_emitsVaultActivatedEvent() public {
        _initFactory();
        address expectedVault = factory.vaultAddress(owner1);

        vm.expectEmit(true, false, false, true);
        emit BittyV1VaultFactory.VaultActivated(owner1);

        vm.prank(owner1);
        factory.activateVault();
        assertTrue(expectedVault.code.length > 0);
    }

    function test_ActivateVaultFor_initializesVaultConfig() public {
        _initFactory();
        BittyV1Vault vault = BittyV1Vault(payable(_newVaultFor(owner1)));

        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), owner1));
        assertTrue(vault.isAssetAllowed(wbtcAddress));
        assertTrue(vault.isAssetAllowed(wethAddress));
        assertTrue(vault.isStableCoinAllowed(usdtAddress));
        assertTrue(vault.isStableCoinAllowed(usdcAddress));
    }

    function test_ActivatedVault_ownerSetsAssetManager() public {
        _initFactory();
        BittyV1Vault vault = BittyV1Vault(payable(_newVaultFor(owner1)));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), owner1));
        assertEq(effectiveAssetManager(address(vault)), assetManagerAddress);
    }

    function test_ActivatedVault_settingAssetManagerReplacesThePrevious() public {
        _initFactory();
        address assetManager1 = makeAddr("assetManager1");
        address assetManager2 = makeAddr("assetManager2");

        vm.startPrank(owner1);
        factory.activateVault();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(factory.vaultAddress(owner1)));
        vaultInstance.setAssetManager(assetManager1, 0);
        vaultInstance.setAssetManager(assetManager2, 0);
        vm.stopPrank();

        // A vault has a single asset manager; the second set replaces the first.
        assertEq(effectiveAssetManager(address(vaultInstance)), assetManager2);
    }

    function test_ActivateVaultFor_nonOwnerCannotGrantRoles() public {
        _initFactory();
        BittyV1Vault vault = BittyV1Vault(payable(_newVaultFor(owner1)));

        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(owner2);
        vm.expectRevert(OwnershipNotTransferable.selector);
        vault.grantRole(adminRole, owner2);
    }

    function test_ActivateVault_withTxOriginOwner() public {
        _initFactory();
        address expected = factory.vaultAddress(tx.origin);
        address vault = _newVault();
        assertEq(vault, expected);
        assertTrue(BittyV1Vault(payable(vault)).hasRole(BittyV1Vault(payable(vault)).DEFAULT_ADMIN_ROLE(), tx.origin));
        assertEq(effectiveAssetManager(vault), assetManagerAddress);
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
        vm.expectRevert(OwnershipNotTransferable.selector);
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
        factory.activateVault();
    }

    function test_vaultAddressMatchesActivation() public {
        _initFactory();
        address predicted = factory.vaultAddress(owner1);
        address actual = _activateVault(owner1, assetManagerAddress);
        assertEq(predicted, actual);
    }

    function _contains(address[] memory list, address a) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }
}

contract ActivateVaultWithAssetsTest is Test {
    /// The address that will actually be msg.sender for the next call, honouring an active prank.
    function _self() internal view returns (address) {
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        return mode == VmSafe.CallerMode.None ? address(this) : sender;
    }

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    BittyV1VaultFactory internal factory;
    BittyV1Guard internal guard;
    WETH internal weth;
    MockERC20 internal wbtc;
    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockLendingProtocol internal lending;

    address internal user;
    uint256 internal userPk;
    uint256 internal deadline;

    address[] internal noProtocols;
    AutoYield[] internal noYield;

    function setUp() public {
        weth = new WETH();
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        lending = new MockLendingProtocol();

        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        deployCodeTo("BittyV1Guard.sol:BittyV1Guard", BITTY_GUARD);
        vm.stopPrank();
        guard = BittyV1Guard(BITTY_GUARD);
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guard.grantRole(guard.ASSET_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.PROTOCOL_MANAGER_ROLE(), tx.origin);
        guardAddAssets(address(guard), _assets(address(weth), address(wbtc)));
        guardAddStableCoins(address(guard), _assets(address(usdc), address(usdt)));
        guardAddProtocols(address(guard), _single(address(lending)));
        vm.stopPrank();

        address vaultImpl = address(new BittyV1Vault(address(new BittyV1VaultDeFiFacet()), address(0xA07E1D)));
        address defiFacet = address(new BittyV1VaultDeFiFacet());
        factory = new BittyV1VaultFactory();
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImpl, address(weth));

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

    function test_revertsWhenAlreadyActivated() public {
        uint256 amount = 1e8;
        wbtc.mint(user, amount);

        vm.startPrank(user);
        factory.activateVault();

        vm.expectRevert(VaultAlreadyActivated.selector);
        factory.activateVault();
        vm.stopPrank();
    }

    function test_emitsVaultActivated() public {
        uint256 amount = 1e8;
        wbtc.mint(user, amount);

        vm.prank(user);
        vm.expectEmit(true, false, false, true);
        emit BittyV1VaultFactory.VaultActivated(user);
        factory.activateVault();
    }

    /// ETH sent to the predicted address before deploy is wrapped by initialize; a WETH that reverts
    /// on deposit must take the whole activation down rather than silently strand the ETH.
    function test_revertsWhenEthWrapFails() public {
        RevertingWeth badWeth = new RevertingWeth();
        BittyV1VaultFactory badFactory = new BittyV1VaultFactory();
        address vaultImpl = address(new BittyV1Vault(address(new BittyV1VaultDeFiFacet()), address(0xA07E1D)));
        address defiFacet = address(new BittyV1VaultDeFiFacet());
        vm.prank(badFactory.DEPLOYER(), badFactory.DEPLOYER());
        badFactory.initialize(vaultImpl, address(badWeth));

        vm.deal(badFactory.vaultAddress(user), 1 ether);
        vm.prank(user);
        vm.expectRevert(bytes("no deposit"));
        badFactory.activateVault();
    }

    /// The only way ETH reaches a vault at activation now: sent to the predicted address beforehand.
    function test_ethDepositBeforeDeployWrapsToWeth() public {
        uint256 ethAmount = 1 ether;
        address vault = factory.vaultAddress(user);
        vm.deal(vault, ethAmount);

        vm.prank(user);
        factory.activateVault();

        assertEq(weth.balanceOf(vault), ethAmount, "deposited ETH wrapped to WETH by initialize");
        assertEq(vault.balance, 0, "no raw native ETH left in vault");
    }
}

contract RevertingWeth {
    function deposit() external payable {
        revert("no deposit");
    }
}
