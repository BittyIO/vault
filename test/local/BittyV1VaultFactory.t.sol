// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {IVaultFull} from "../helpers/IVaultFull.sol";
import {MockIntentProtocol} from "../helpers/MockIntentProtocol.sol";
import {MockSettlement} from "../helpers/MockSettlement.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {
    AddressZero,
    OwnershipNotTransferable,
    NoRescueTarget,
    RiskControlLevel,
    AutoYield
} from "../../src/interfaces/IBittyV1Vault.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {
    IBittyV1VaultFactory,
    VaultAlreadyActivated,
    NotDeployer,
    EthTransferFailed
} from "../../src/interfaces/IBittyV1VaultFactory.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {IBittyV1Guard, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
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
    IBittyV1VaultFactory.AssetInput[] internal noDeposits;
    AutoYield[] internal noYield;
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
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
        vault = factory.vaultAddress(owner);
        if (assetManager != address(0)) {
            BittyV1Vault(payable(vault)).setAssetManager(assetManager);
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

    function _oneAddr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function test_InitializeRevertZeroDefiFacet() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        vm.expectRevert(AddressZero.selector);
        factory.initialize(vaultImplementation, address(0), guardAddress, wethAddress);
    }

    function test_ActivateRevertUnregisteredStakingProtocol() public {
        _initFactory();
        vm.prank(owner1);
        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            _oneAddr(makeAddr("unregisteredStaking")),
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
    }

    function test_ActivateRevertRouteAssetNotRegistered() public {
        _initFactory();
        // Register a lending protocol so only the route's asset is the failing check.
        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addLendingProtocols(_oneAddr(aaveV3Address));

        AutoYield[] memory routes = new AutoYield[](1);
        routes[0] = AutoYield({asset: makeAddr("unregisteredAsset"), protocol: aaveV3Address, isSupplying: true});

        vm.prank(owner1);
        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            routes,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
    }

    function test_ActivateRevertRouteProtocolNotRegistered() public {
        _initFactory();
        AutoYield[] memory routes = new AutoYield[](1);
        routes[0] = AutoYield({
            asset: wethAddress, // registered
            protocol: makeAddr("unregisteredLending"),
            isSupplying: true
        });

        vm.prank(owner1);
        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            routes,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
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
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            invalidAddressArray,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
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
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
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
                noYield,
                address(0),
                noDeposits,
                vaultAssetAddresses,
                lendingProtocols,
                stakingProtocols,
                ammProtocols,
                intentProtocols,
                RiskControlLevel.Zero
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
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            invalidStableCoinArray,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
    }

    function test_ActivateVaultRevertsIfLendingProtocolNotRegistered() public {
        _initFactory();
        address[] memory invalidLendingProviderArray = new address[](1);
        invalidLendingProviderArray[0] = makeAddr("invalidLendingProtocol");
        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            invalidLendingProviderArray,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
    }

    function test_ActivateVaultRevertsIfAMMProtocolNotRegistered() public {
        _initFactory();
        address[] memory invalidAMMProviderArray = new address[](1);
        invalidAMMProviderArray[0] = makeAddr("invalidAMMProtocol");
        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            invalidAMMProviderArray,
            intentProtocols,
            RiskControlLevel.Zero
        );
    }

    function test_ActivateVaultRevertsIfIntentProtocolNotRegistered() public {
        _initFactory();
        address[] memory invalidIntentProviderArray = new address[](1);
        invalidIntentProviderArray[0] = makeAddr("invalidIntentProtocol");
        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            invalidIntentProviderArray,
            RiskControlLevel.Zero
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
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            selectedIntentProtocols,
            RiskControlLevel.Zero
        );
        address vault = factory.vaultAddress(owner1);

        assertTrue(vault.code.length > 0, "Vault should be activated");
        address[] memory activatedIntentProtocols = IVaultFull(payable(vault)).getIntentProtocols();
        assertEq(activatedIntentProtocols.length, 1);
        assertEq(activatedIntentProtocols[0], intentProtocol);
    }

    // Gasless off-chain orders validate through the intent protocol's per-vault clone (owner == vault).
    // With no on-chain trade call left to lazily clone it, registration must create the clone, or every
    // CoW order fails as InvalidEip1271Signature. Guards the offchain-migration regression.
    function test_ActivateVaultClonesIntentProtocolAtRegistration() public {
        _initFactory();
        address intentProtocol = address(new MockIntentProtocol());
        address[] memory selectedIntentProtocols = new address[](1);
        selectedIntentProtocols[0] = intentProtocol;

        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addIntentProtocols(selectedIntentProtocols);

        vm.prank(owner1);
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            selectedIntentProtocols,
            RiskControlLevel.Zero
        );
        address vault = factory.vaultAddress(owner1);

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

        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addIntentProtocols(sel);

        vm.prank(owner1);
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            sel,
            RiskControlLevel.Zero
        );
        address vault = factory.vaultAddress(owner1);

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

    function test_ActivateVaultWithEmptyArrays() public {
        _initFactory();

        vm.prank(owner1);
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            RiskControlLevel.Zero
        );
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
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            multipleAssets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );

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
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            activationAssets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );

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
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            multipleAMMProtocols,
            intentProtocols,
            RiskControlLevel.Zero
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
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            mixedAssets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
    }

    function test_ActivateVaultRevertsIfMultipleStableCoinsOneNotRegistered() public {
        _initFactory();
        address[] memory mixedStableCoins = new address[](3);
        mixedStableCoins[0] = usdtAddress;
        mixedStableCoins[1] = usdcAddress;
        mixedStableCoins[2] = makeAddr("invalidStableCoin");

        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            mixedStableCoins,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
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
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            mixedLendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
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
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            mixedAMMProtocols,
            intentProtocols,
            RiskControlLevel.Zero
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
                noYield,
                address(0),
                noDeposits,
                vaultAssetAddresses,
                lendingProtocols,
                stakingProtocols,
                ammProtocols,
                intentProtocols,
                RiskControlLevel.Zero
            );
        } else {
            vm.etch(computedAddr, minimalBytecode);
            if (computedAddr.code.length > 0) {
                vm.prank(owner1);
                vm.expectRevert(VaultAlreadyActivated.selector);
                factory.activateVault(
                    noYield,
                    address(0),
                    noDeposits,
                    vaultAssetAddresses,
                    lendingProtocols,
                    stakingProtocols,
                    ammProtocols,
                    intentProtocols,
                    RiskControlLevel.Zero
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
        // address, so the pre-activation asset manager-injection vector is structurally
        // impossible.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            RiskControlLevel.Zero
        );
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
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
    }

    function test_ActivateVaultFor_emitsVaultActivatedEvent() public {
        _initFactory();
        address expectedVault = factory.vaultAddress(owner1);

        vm.expectEmit(true, false, false, true);
        emit BittyV1VaultFactory.VaultActivated(owner1);

        vm.prank(owner1);
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
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

    function test_ActivatedVault_ownerSetsAssetManager() public {
        _initFactory();
        BittyV1Vault vault = BittyV1Vault(payable(_newVaultFor(owner1)));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), owner1));
        assertEq(vault.getAssetManager(), assetManagerAddress);
    }

    function test_ActivatedVault_settingAssetManagerReplacesThePrevious() public {
        _initFactory();
        address assetManager1 = makeAddr("assetManager1");
        address assetManager2 = makeAddr("assetManager2");

        vm.startPrank(owner1);
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            RiskControlLevel.Zero
        );
        BittyV1Vault vaultInstance = BittyV1Vault(payable(factory.vaultAddress(owner1)));
        vaultInstance.setAssetManager(assetManager1);
        vaultInstance.setAssetManager(assetManager2);
        vm.stopPrank();

        // A vault has a single asset manager; the second set replaces the first.
        assertEq(vaultInstance.getAssetManager(), assetManager2);
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
        assertEq(BittyV1Vault(payable(vault)).getAssetManager(), assetManagerAddress);
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
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            RiskControlLevel.Zero
        );
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
    MockLendingProtocol internal lending;

    address internal user;
    uint256 internal userPk;
    uint256 internal deadline;

    address[] internal noProtocols;
    IBittyV1VaultFactory.AssetInput[] internal noDeposits;
    AutoYield[] internal noYield;

    function setUp() public {
        weth = new WETH();
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        lending = new MockLendingProtocol();

        guard = new BittyV1Guard();
        vm.startPrank(tx.origin);
        guard.grantRole(guard.ASSET_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.STABLE_COIN_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.LENDING_MANAGER_ROLE(), tx.origin);
        guard.addAssets(_assets(address(weth), address(wbtc)));
        guard.addStableCoins(_single(address(usdc)));
        guard.addLendingProtocols(_single(address(lending)));
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
        factory.activateVault(
            noYield,
            address(0),
            deposits,
            _single(address(wbtc)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
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
        factory.activateVault(
            noYield,
            address(0),
            deposits,
            _single(address(wbtc)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
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
        factory.activateVault(
            noYield,
            address(0),
            deposits,
            _assets(address(wbtc), address(usdc)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
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
        factory.activateVault{value: ethAmount}(
            noYield,
            address(0),
            deposits,
            _assets(address(wbtc), address(weth)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
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
        factory.activateVault{value: ethAmount}(
            noYield,
            address(0),
            _noDeposits(),
            _single(address(weth)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
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
        factory.activateVault(
            noYield,
            address(0),
            deposits,
            _single(address(wbtc)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
        );

        assertEq(wbtc.balanceOf(vault), amount, "transfer still succeeds via pre-set allowance");
    }

    function test_revertsWhenAssetNotRegistered() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(user, 1e18);
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(_permit(stray, 1e18));

        vm.prank(user);
        vm.expectRevert(NotRegistered.selector);
        factory.activateVault(
            noYield,
            address(0),
            deposits,
            _single(address(stray)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
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
        factory.activateVault(
            noYield,
            address(0),
            deposits,
            _single(address(wbtc)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
        );
    }

    function test_revertsWhenApprovedPathNotApproved() public {
        uint256 amount = 1e8;
        wbtc.mint(user, amount);
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(_approved(wbtc, amount));

        vm.prank(user);
        vm.expectRevert();
        factory.activateVault(
            noYield,
            address(0),
            deposits,
            _single(address(wbtc)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
        );
    }

    function test_revertsWhenAlreadyActivated() public {
        uint256 amount = 1e8;
        wbtc.mint(user, amount);
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(_permit(wbtc, amount));

        vm.startPrank(user);
        factory.activateVault(
            noYield,
            address(0),
            noDeposits,
            _single(address(wbtc)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
        );

        vm.expectRevert(VaultAlreadyActivated.selector);
        factory.activateVault(
            noYield,
            address(0),
            deposits,
            _single(address(wbtc)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
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
        factory.activateVault(
            noYield,
            address(0),
            deposits,
            _single(address(wbtc)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
        );
    }

    function test_revertsWhenEthForwardFails() public {
        // ETH is forwarded to the code-less predicted address (a plain value transfer that succeeds),
        // so the failure now surfaces from initialize's WETH-wrap step rather than as EthTransferFailed.
        RevertingWeth badWeth = new RevertingWeth();
        BittyV1VaultFactory badFactory = new BittyV1VaultFactory();
        address vaultImpl = address(new BittyV1Vault());
        address defiFacet = address(new BittyV1VaultDeFiFacet());
        vm.prank(badFactory.DEPLOYER(), badFactory.DEPLOYER());
        badFactory.initialize(vaultImpl, defiFacet, address(guard), address(badWeth));

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(bytes("no deposit"));
        badFactory.activateVault{value: 1 ether}(
            noYield,
            address(0),
            _noDeposits(),
            new address[](0),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
        );
    }

    function _route(address asset, address protocol, bool isSupplying) internal pure returns (AutoYield[] memory arr) {
        arr = new AutoYield[](1);
        arr[0] = AutoYield({asset: asset, protocol: protocol, isSupplying: isSupplying});
    }

    function test_autoYieldRouteDrivesRegistration() public {
        // The route's asset and protocol are NOT in the explicit arrays; activation must register them.
        AutoYield[] memory routes = _route(address(wbtc), address(lending), true);

        vm.prank(user);
        factory.activateVault(
            routes,
            address(0),
            _noDeposits(),
            new address[](0),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
        );

        IVaultFull vault = IVaultFull(payable(factory.vaultAddress(user)));

        address[] memory assets = vault.getAssets();
        assertEq(assets.length, 1, "route asset registered");
        assertEq(assets[0], address(wbtc));

        address[] memory lendingProtocols = vault.getLendingProtocols();
        assertEq(lendingProtocols.length, 1, "route protocol registered");
        assertEq(lendingProtocols[0], address(lending));

        (address[] memory protocols, bool[] memory isSupplyings) = vault.getAutoYieldings(_single(address(wbtc)));
        assertEq(protocols[0], address(lending));
        assertTrue(isSupplyings[0]);
    }

    function test_zeroProtocolAutoYieldReverts() public {
        AutoYield[] memory routes = _route(address(wbtc), address(0), true);

        vm.prank(user);
        vm.expectRevert(AddressZero.selector);
        factory.activateVault(
            routes,
            address(0),
            _noDeposits(),
            new address[](0),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
        );
    }

    function test_ethDepositBeforeDeployWrapsToWeth() public {
        uint256 ethAmount = 1 ether;
        vm.deal(user, ethAmount);
        address vault = factory.vaultAddress(user);

        vm.prank(user);
        factory.activateVault{value: ethAmount}(
            noYield,
            address(0),
            _noDeposits(),
            _single(address(weth)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
        );

        assertEq(weth.balanceOf(vault), ethAmount, "deposited ETH wrapped to WETH by initialize");
        assertEq(vault.balance, 0, "no raw native ETH left in vault");
    }

    function test_autoYieldsInitialDeposit() public {
        uint256 amount = 5e8;
        wbtc.mint(user, amount);
        vm.prank(user);
        wbtc.approve(address(factory), amount);

        address vault = factory.vaultAddress(user);
        IBittyV1VaultFactory.AssetInput[] memory deposits = _deposits(_approved(wbtc, amount));
        AutoYield[] memory routes = _route(address(wbtc), address(lending), true);

        vm.prank(user);
        factory.activateVault(
            routes,
            address(0),
            deposits,
            _single(address(wbtc)),
            noProtocols,
            noProtocols,
            noProtocols,
            noProtocols,
            RiskControlLevel.Zero
        );

        assertEq(
            IVaultFull(payable(vault)).getSuppliedBalances(_single(address(lending)), _single(address(wbtc)))[0],
            amount,
            "initial deposit routed into the lending protocol"
        );
        assertEq(wbtc.balanceOf(vault), 0, "no spendable WBTC left in vault");
    }
}

contract RevertingWeth {
    function deposit() external payable {
        revert("no deposit");
    }
}
