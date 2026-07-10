// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {AddressZero} from "../../src/interfaces/IBittyV1Vault.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {VaultAlreadyDeployed, NotDeployer} from "../../src/interfaces/IBittyV1VaultFactory.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {IBittyV1Guard, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {
    IAccessControlDefaultAdminRules
} from "openzeppelin-contracts/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

contract BittyV1VaultFactoryTest is Test {
    BittyV1VaultFactory public factory;
    address public vaultImplementation;
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

    function _assetManagers(address manager) internal pure returns (address[] memory managers) {
        managers = new address[](1);
        managers[0] = manager;
    }

    function _deployVault(address owner, string memory name, address assetManager) internal returns (address) {
        return factory.deployVaultWithSelected(
            owner,
            name,
            _assetManagers(assetManager),
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );
    }

    function _newVault() internal returns (address) {
        return _deployVault(tx.origin, "main", assetManagerAddress);
    }

    function _newVaultFor(address owner) internal returns (address) {
        return _deployVault(owner, "main", assetManagerAddress);
    }

    function _initFactory() internal {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
    }

    function test_deployedVault_hasOneDayDefaultAdminDelay() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_deployVault(owner1, "main", assetManagerAddress)));
        assertEq(vaultInstance.OWNER_TRANSFER_DELAY(), 1 days);
        assertEq(vaultInstance.defaultAdminDelay(), 1 days);
    }

    function test_deployedVault_ownerIsAdminInstantly() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_deployVault(owner1, "main", assetManagerAddress)));

        assertEq(vaultInstance.defaultAdmin(), owner1);
        assertTrue(vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), owner1));

        vm.prank(owner1);
        vaultInstance.setName("renamed");
        assertEq(vaultInstance.vaultName(), "renamed");
    }

    function test_deployedVault_adminTransferRequiresOneDayDelay() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_deployVault(owner1, "main", assetManagerAddress)));

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

    function test_deployedVault_adminTransferSucceedsAfterOneDay() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_deployVault(owner1, "main", assetManagerAddress)));

        vm.prank(owner1);
        vaultInstance.beginDefaultAdminTransfer(owner2);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(owner2);
        vaultInstance.acceptDefaultAdminTransfer();

        assertEq(vaultInstance.defaultAdmin(), owner2);
        assertTrue(vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), owner2));
        assertFalse(vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), owner1));
    }

    function test_deployedVault_cancelDefaultAdminTransfer() public {
        _initFactory();
        BittyV1Vault vaultInstance = BittyV1Vault(payable(_deployVault(owner1, "main", assetManagerAddress)));

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
        factory.initialize(address(0), guardAddress, wethAddress);

        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        vm.expectRevert(AddressZero.selector);
        factory.initialize(vaultImplementation, address(0), wethAddress);

        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        vm.expectRevert(AddressZero.selector);
        factory.initialize(vaultImplementation, guardAddress, address(0));
    }

    function test_initializeOnlyByDeployer() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker, attacker);
        vm.expectRevert(NotDeployer.selector);
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        assertEq(factory.guardAddress(), guardAddress);
    }

    function test_DeployVaultRevertsIfAddressNotRegistered() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory invalidAddressArray = new address[](1);
        invalidAddressArray[0] = makeAddr("invalidAddress");
        vm.expectRevert(NotRegistered.selector);
        factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            invalidAddressArray,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );
    }

    function test_DeployVaultForDifferentowners() public {
        _initFactory();
        address vault1 = _newVaultFor(owner1);
        address vault2 = _newVaultFor(owner2);
        assertTrue(vault1 != vault2, "Different owners should get different vault addresses");
        assertTrue(vault1 != address(0), "Vault1 should not be zero address");
        assertTrue(vault2 != address(0), "Vault2 should not be zero address");
    }

    function test_ComputeVaultAddress() public {
        _initFactory();
        address computedAddress = factory.computeVaultAddress(owner1, "main");
        assertTrue(computedAddress != address(0), "Computed address should not be zero");

        address deployedAddress = _newVaultFor(owner1);
        assertTrue(deployedAddress != address(0), "Deployed address should not be zero");
        assertEq(computedAddress, deployedAddress, "Computed address should match deployment");
    }

    function test_SameOwnerAlreadDeployed() public {
        _initFactory();
        _newVaultFor(owner1);

        vm.expectRevert(VaultAlreadyDeployed.selector);
        _newVaultFor(owner1);
    }

    function test_SameownerSameSaltRevertsIfVaultExists() public {
        _initFactory();
        address vault1 = _newVaultFor(owner1);

        assertTrue(vault1 != address(0), "First vault should be deployed");

        vm.expectRevert(VaultAlreadyDeployed.selector);
        _newVaultFor(owner1);
    }

    function test_DeployedVaultCanBeInitialized() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address vaultAddress = _newVault();
        BittyV1Vault vault = BittyV1Vault(payable(vaultAddress));

        assertTrue(
            BittyV1Vault(payable(vaultAddress))
                .hasRole(BittyV1Vault(payable(vaultAddress)).DEFAULT_ADMIN_ROLE(), tx.origin),
            "Owner should hold DEFAULT_ADMIN_ROLE"
        );

        address[] memory assets = vault.getAssets();
        assertEq(assets[0], wbtcAddress, "WBTC address should be set");
        assertEq(assets[1], wethAddress, "WETH address should be set");
        address[] memory stableCoins = vault.getStableCoins();
        assertEq(stableCoins[0], usdtAddress, "USDT address should be set");
        assertEq(stableCoins[1], usdcAddress, "USDC address should be set");
    }

    function test_DeployVaultRevertsIfVaultAlreadyExistsAtComputedAddress() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        bytes32 salt = keccak256(abi.encodePacked(owner1, "main"));
        address computedAddr = Clones.predictDeterministicAddress(vaultImplementation, salt, address(factory));

        bytes memory minimalBytecode =
            hex"6080604052348015600f57600080fd5b50603f80601d6000396000f3fe6080604052600080fdfea2646970667358221220";
        address deployedAddr;
        assembly {
            deployedAddr := create2(0, add(minimalBytecode, 0x20), mload(minimalBytecode), salt)
        }

        if (deployedAddr == computedAddr && deployedAddr.code.length > 0) {
            vm.expectRevert(VaultAlreadyDeployed.selector);
            _newVaultFor(owner1);
        }
    }

    function test_InitializeSuccess() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        assertEq(factory.guardAddress(), guardAddress, "BittyV1Guard address should be set");
    }

    function test_DeployVaultRevertsIfStableCoinNotRegistered() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory invalidStableCoinArray = new address[](1);
        invalidStableCoinArray[0] = makeAddr("invalidStableCoin");
        vm.expectRevert(NotRegistered.selector);
        factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            invalidStableCoinArray,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );
    }

    function test_DeployVaultRevertsIfLendingProtocolNotRegistered() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory invalidLendingProviderArray = new address[](1);
        invalidLendingProviderArray[0] = makeAddr("invalidLendingProtocol");
        vm.expectRevert(NotRegistered.selector);
        factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            vaultAssetAddresses,
            invalidLendingProviderArray,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );
    }

    function test_DeployVaultRevertsIfAMMProtocolNotRegistered() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory invalidAMMProviderArray = new address[](1);
        invalidAMMProviderArray[0] = makeAddr("invalidAMMProtocol");
        vm.expectRevert(NotRegistered.selector);
        factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            invalidAMMProviderArray,
            intentProtocols
        );
    }

    function test_DeployVaultRevertsIfIntentProtocolNotRegistered() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory invalidIntentProviderArray = new address[](1);
        invalidIntentProviderArray[0] = makeAddr("invalidIntentProtocol");
        vm.expectRevert(NotRegistered.selector);
        factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            invalidIntentProviderArray
        );
    }

    function test_DeployVaultWithIntentProtocols() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address intentProtocol = makeAddr("intentProtocol");
        address[] memory selectedIntentProtocols = new address[](1);
        selectedIntentProtocols[0] = intentProtocol;

        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addIntentProtocols(selectedIntentProtocols);

        address vault = factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            selectedIntentProtocols
        );

        assertTrue(vault != address(0), "Vault should be deployed");
        address[] memory deployedIntentProtocols = BittyV1Vault(payable(vault)).getIntentProtocols();
        assertEq(deployedIntentProtocols.length, 1);
        assertEq(deployedIntentProtocols[0], intentProtocol);
    }

    function test_DeployVaultWithEmptyArrays() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        address vault = factory.deployVault(owner1, "main");

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultEmitsEvent() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        address vault = _newVault();

        assertTrue(vault != address(0), "Vault should be deployed");

        BittyV1Vault vaultInstance = BittyV1Vault(payable(vault));
        assertTrue(
            vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), tx.origin), "Owner should hold DEFAULT_ADMIN_ROLE"
        );
    }

    function test_ComputeVaultAddressForDifferentowners() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address computed1 = factory.computeVaultAddress(owner1, "main");
        address computed2 = factory.computeVaultAddress(owner2, "main");

        assertTrue(computed1 != computed2, "Different owners should compute to different addresses");
        assertTrue(computed1 != address(0), "Computed address should not be zero");
        assertTrue(computed2 != address(0), "Computed address should not be zero");
    }

    function test_DeployVaultWithMultipleAssets() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory multipleAssets = new address[](3);
        multipleAssets[0] = wbtcAddress;
        multipleAssets[1] = wethAddress;
        multipleAssets[2] = makeAddr("asset3");

        address[] memory newAsset = new address[](1);
        newAsset[0] = multipleAssets[2];
        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addAssets(newAsset);

        address vault = factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            multipleAssets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultWithMultipleStableCoins() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory multipleStableCoins = new address[](3);
        multipleStableCoins[0] = usdtAddress;
        multipleStableCoins[1] = usdcAddress;
        multipleStableCoins[2] = makeAddr("stableCoin3");

        address[] memory newStableCoin = new address[](1);
        newStableCoin[0] = multipleStableCoins[2];
        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addStableCoins(newStableCoin);

        address[] memory deployAssets = new address[](assetAddresses.length + multipleStableCoins.length);
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            deployAssets[i] = assetAddresses[i];
        }
        for (uint256 i = 0; i < multipleStableCoins.length; i++) {
            deployAssets[assetAddresses.length + i] = multipleStableCoins[i];
        }

        address vault = factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            deployAssets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultWithMultipleLendingProtocols() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address LendingProtocol1 = makeAddr("LendingProtocol1");
        address LendingProtocol2 = makeAddr("LendingProtocol2");
        address[] memory multipleLendingProtocols = new address[](2);
        multipleLendingProtocols[0] = LendingProtocol1;
        multipleLendingProtocols[1] = LendingProtocol2;

        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addLendingProtocols(multipleLendingProtocols);

        address vault = _newVaultFor(owner1);

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultWithMultipleAMMProtocols() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address swapProtocol1 = makeAddr("swapProtocol1");
        address swapProtocol2 = makeAddr("swapProtocol2");
        address[] memory multipleAMMProtocols = new address[](2);
        multipleAMMProtocols[0] = swapProtocol1;
        multipleAMMProtocols[1] = swapProtocol2;

        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addAMMProtocols(multipleAMMProtocols);

        address vault = factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            multipleAMMProtocols,
            intentProtocols
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultRevertsIfMultipleAssetsOneNotRegistered() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory mixedAssets = new address[](3);
        mixedAssets[0] = wbtcAddress;
        mixedAssets[1] = wethAddress;
        mixedAssets[2] = makeAddr("invalidAsset");

        vm.expectRevert(NotRegistered.selector);
        factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            mixedAssets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );
    }

    function test_DeployVaultRevertsIfMultipleStableCoinsOneNotRegistered() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory mixedStableCoins = new address[](3);
        mixedStableCoins[0] = usdtAddress;
        mixedStableCoins[1] = usdcAddress;
        mixedStableCoins[2] = makeAddr("invalidStableCoin");

        vm.expectRevert(NotRegistered.selector);
        factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            mixedStableCoins,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );
    }

    function test_DeployVaultRevertsIfMultipleLendingProtocolsOneNotRegistered() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address LendingProtocol1 = makeAddr("LendingProtocol1");
        address[] memory mixedLendingProtocols = new address[](2);
        mixedLendingProtocols[0] = LendingProtocol1;
        mixedLendingProtocols[1] = makeAddr("invalidLendingProtocol");

        address[] memory validProtocol = new address[](1);
        validProtocol[0] = LendingProtocol1;
        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addLendingProtocols(validProtocol);

        vm.expectRevert(NotRegistered.selector);
        factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            vaultAssetAddresses,
            mixedLendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );
    }

    function test_DeployVaultRevertsIfMultipleAMMProtocolsOneNotRegistered() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address swapProtocol1 = makeAddr("swapProtocol1");
        address[] memory mixedAMMProtocols = new address[](2);
        mixedAMMProtocols[0] = swapProtocol1;
        mixedAMMProtocols[1] = makeAddr("invalidAMMProtocol");

        address[] memory validProtocol = new address[](1);
        validProtocol[0] = swapProtocol1;
        vm.prank(tx.origin);
        IBittyV1Guard(guardAddress).addAMMProtocols(validProtocol);

        vm.expectRevert(NotRegistered.selector);
        factory.deployVaultWithSelected(
            owner1,
            "main",
            _assetManagers(assetManagerAddress),
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            mixedAMMProtocols,
            intentProtocols
        );
    }

    function test_DeployVaultRevertsIfVaultAlreadyExistsAtComputedAddressForced() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        bytes32 salt = keccak256(abi.encodePacked(owner1, "main"));
        address computedAddr = Clones.predictDeterministicAddress(vaultImplementation, salt, address(factory));

        bytes memory minimalBytecode =
            hex"6080604052348015600f57600080fd5b50603f80601d6000396000f3fe6080604052600080fdfea2646970667358221220";

        address deployedAddr;
        assembly {
            deployedAddr := create2(0, add(minimalBytecode, 0x20), mload(minimalBytecode), salt)
        }

        if (deployedAddr == computedAddr && deployedAddr.code.length > 0) {
            vm.expectRevert(VaultAlreadyDeployed.selector);
            _newVaultFor(owner1);
        } else {
            vm.etch(computedAddr, minimalBytecode);
            if (computedAddr.code.length > 0) {
                vm.expectRevert(VaultAlreadyDeployed.selector);
                _newVaultFor(owner1);
            }
        }
    }

    function test_ComputeAddressInternalFunction() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        address addr1 = factory.computeVaultAddress(owner1, "main");
        address addr2 = factory.computeVaultAddress(owner2, "main");

        assertTrue(addr1 != address(0), "Computed address should not be zero");
        assertTrue(addr2 != address(0), "Computed address should not be zero");
        assertTrue(addr1 != addr2, "Different owners should produce different addresses");

        address addr1Again = factory.computeVaultAddress(owner1, "main");
        assertEq(addr1, addr1Again, "Same owner should produce same computed address");
    }

    function test_DeployVaultSuccessWithAllValidParameters() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        address vault = _newVault();

        assertTrue(vault != address(0), "Vault should be deployed");
        BittyV1Vault vaultInstance = BittyV1Vault(payable(vault));
        assertTrue(
            vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), tx.origin), "Owner should hold DEFAULT_ADMIN_ROLE"
        );
    }

    function test_InitializeSetsStateVariables() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        assertEq(factory.guardAddress(), guardAddress, "BittyV1Guard address should be set");
    }

    function test_DeployVaultEmitsVaultDeployedEvent() public {
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        address vault = _newVault();

        assertTrue(vault != address(0), "Vault should be deployed");

        BittyV1Vault vaultInstance = BittyV1Vault(payable(vault));
        assertTrue(
            vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), tx.origin), "Owner should hold DEFAULT_ADMIN_ROLE"
        );
    }

    function test_Factory_initCode() public {
        bytes memory bytecode = type(BittyV1VaultFactory).creationCode;
        console.logBytes32(keccak256(bytecode));
    }

    function test_DeployVaultFor_setsOwner() public {
        _initFactory();
        address vault = _newVaultFor(owner1);
        assertTrue(BittyV1Vault(payable(vault)).hasRole(BittyV1Vault(payable(vault)).DEFAULT_ADMIN_ROLE(), owner1));
    }

    function test_DeployVaultFor_revertOwnerZero() public {
        _initFactory();
        vm.expectRevert(AddressZero.selector);
        factory.deployVault(address(0), "main");
    }

    function test_DeployVaultFor_revertVaultAlreadyDeployed() public {
        _initFactory();
        _newVaultFor(owner1);
        vm.expectRevert(VaultAlreadyDeployed.selector);
        _newVaultFor(owner1);
    }

    function test_DeployVaultFor_emitsVaultDeployedEvent() public {
        _initFactory();
        address expectedVault = factory.computeVaultAddress(owner1, "main");

        vm.expectEmit(true, true, false, true);
        emit BittyV1VaultFactory.VaultDeployed(expectedVault, owner1, "main");

        address vault = _newVaultFor(owner1);
        assertEq(vault, expectedVault);
    }

    function test_DeployVaultFor_initializesVaultConfig() public {
        _initFactory();
        BittyV1Vault vault = BittyV1Vault(payable(_newVaultFor(owner1)));

        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), owner1));
        assertEq(vault.getAssets()[0], wbtcAddress);
        assertEq(vault.getAssets()[1], wethAddress);
        assertEq(vault.getStableCoins()[0], usdtAddress);
        assertEq(vault.getStableCoins()[1], usdcAddress);
    }

    function test_DeployVault_setsRolesAtInit() public {
        _initFactory();
        BittyV1Vault vault = BittyV1Vault(payable(_newVaultFor(owner1)));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), owner1));
        assertTrue(vault.hasRole(vault.ASSET_MANAGER_ROLE(), assetManagerAddress));
    }

    function test_DeployVaultFor_grantsMultipleAssetManagers() public {
        _initFactory();
        address manager1 = makeAddr("manager1");
        address manager2 = makeAddr("manager2");
        address[] memory assetManagers = new address[](2);
        assetManagers[0] = manager1;
        assetManagers[1] = manager2;

        address vault = factory.deployVaultWithSelected(
            owner1,
            "main",
            assetManagers,
            vaultAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );

        BittyV1Vault vaultInstance = BittyV1Vault(payable(vault));
        assertTrue(vaultInstance.hasRole(vaultInstance.ASSET_MANAGER_ROLE(), manager1));
        assertTrue(vaultInstance.hasRole(vaultInstance.ASSET_MANAGER_ROLE(), manager2));
    }

    function test_DeployVaultAllSelected_usesAllGuardAssetsAndProtocols() public {
        _initFactory();
        address vault = factory.deployVaultAllSelected(owner1, "main", _assetManagers(assetManagerAddress));

        BittyV1Vault vaultInstance = BittyV1Vault(payable(vault));
        assertTrue(vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), owner1));
        assertTrue(vaultInstance.hasRole(vaultInstance.ASSET_MANAGER_ROLE(), assetManagerAddress));
        assertEq(vaultInstance.getAssets().length, assetAddresses.length);
        assertEq(vaultInstance.getAssets()[0], wbtcAddress);
        assertEq(vaultInstance.getAssets()[1], wethAddress);
        assertEq(vaultInstance.getStableCoins().length, stableCoinAddresses.length);
        assertEq(vaultInstance.getStableCoins()[0], usdtAddress);
        assertEq(vaultInstance.getStableCoins()[1], usdcAddress);
        assertEq(vaultInstance.getAMMProtocols().length, ammProtocols.length);
        assertEq(vaultInstance.getAMMProtocols()[0], ammProtocols[0]);
        assertEq(vaultInstance.getIntentProtocols().length, intentProtocols.length);
    }

    function test_DeployVaultFor_nonOwnerCannotGrantRoles() public {
        _initFactory();
        BittyV1Vault vault = BittyV1Vault(payable(_newVaultFor(owner1)));

        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(owner2);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        vault.grantRole(adminRole, owner2);
    }

    function test_DeployVault_withTxOriginOwner() public {
        _initFactory();
        address expected = factory.computeVaultAddress(tx.origin, "main");
        address vault = _newVault();
        assertEq(vault, expected);
        assertTrue(BittyV1Vault(payable(vault)).hasRole(BittyV1Vault(payable(vault)).DEFAULT_ADMIN_ROLE(), tx.origin));
        assertTrue(
            BittyV1Vault(payable(vault)).hasRole(BittyV1Vault(payable(vault)).ASSET_MANAGER_ROLE(), assetManagerAddress)
        );
    }

    function test_DeployVault_multisigOwnerAddress() public {
        _initFactory();
        address multisigOwner = makeAddr("gnosisSafe");
        address vault = _deployVault(multisigOwner, "main", assetManagerAddress);

        assertEq(factory.computeVaultAddress(multisigOwner, "main"), vault);
        assertTrue(
            BittyV1Vault(payable(vault)).hasRole(BittyV1Vault(payable(vault)).DEFAULT_ADMIN_ROLE(), multisigOwner)
        );

        bytes32 adminRole = BittyV1Vault(payable(vault)).DEFAULT_ADMIN_ROLE();
        vm.prank(owner1);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        BittyV1Vault(payable(vault)).grantRole(adminRole, makeAddr("other"));
    }

    // ============ Multi-vault per owner ============

    function test_sameOwnerCanDeployMultipleVaultsWithDifferentNames() public {
        _initFactory();
        address vault1 = _deployVault(owner1, "savings", assetManagerAddress);
        address vault2 = _deployVault(owner1, "trading", assetManagerAddress);

        assertTrue(vault1 != vault2, "Different names produce different vault addresses");
        assertEq(BittyV1Vault(payable(vault1)).vaultName(), "savings");
        assertEq(BittyV1Vault(payable(vault2)).vaultName(), "trading");
        assertTrue(BittyV1Vault(payable(vault1)).hasRole(BittyV1Vault(payable(vault1)).DEFAULT_ADMIN_ROLE(), owner1));
        assertTrue(BittyV1Vault(payable(vault2)).hasRole(BittyV1Vault(payable(vault2)).DEFAULT_ADMIN_ROLE(), owner1));
    }

    function test_sameNameDifferentOwnerProducesDifferentVault() public {
        _initFactory();
        address vault1 = _deployVault(owner1, "main", assetManagerAddress);
        address vault2 = _deployVault(owner2, "main", assetManagerAddress);

        assertTrue(vault1 != vault2);
        assertEq(BittyV1Vault(payable(vault1)).vaultName(), "main");
        assertEq(BittyV1Vault(payable(vault2)).vaultName(), "main");
    }

    function test_deployVault_sameOwnerSameNameReverts() public {
        _initFactory();
        _deployVault(owner1, "savings", assetManagerAddress);

        vm.expectRevert(VaultAlreadyDeployed.selector);
        _deployVault(owner1, "savings", assetManagerAddress);
    }

    function test_computeVaultAddress_matchesDeployForMultipleNames() public {
        _initFactory();
        address predicted1 = factory.computeVaultAddress(owner1, "savings");
        address predicted2 = factory.computeVaultAddress(owner1, "trading");

        address actual1 = _deployVault(owner1, "savings", assetManagerAddress);
        address actual2 = _deployVault(owner1, "trading", assetManagerAddress);

        assertEq(predicted1, actual1);
        assertEq(predicted2, actual2);
        assertTrue(predicted1 != predicted2);
    }

    function test_deployedVault_storesVaultName() public {
        _initFactory();
        address vault = _deployVault(owner1, "my savings", assetManagerAddress);
        assertEq(BittyV1Vault(payable(vault)).vaultName(), "my savings");
    }
}
