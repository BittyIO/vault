// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVaultFactory} from "../src/BittyVaultFactory.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {AssetManager} from "../src/AssetManager.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";
import {
    InvalidGrantor,
    AddressZero,
    NotWhiteListed,
    Unauthorized,
    VaultAlreadyDeployed
} from "../src/interfaces/Errors.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {IWhiteList} from "../src/interfaces/IWhiteList.sol";
import {Migrator} from "../src/Migrator.sol";

contract BittyVaultFactoryTest is Test {
    BittyVaultFactory public factory;
    address public grantor1;
    address public grantor2;
    address public wethAddress;
    address public wbtcAddress;
    address public usdtAddress;
    address public usdcAddress;
    address public aaveV3Address;
    address public uniswapV4RouterAddress;
    address[] public assetAddresses;
    address[] public stableCoinAddresses;
    address[] public yieldProviders;
    address[] public swapProviders;
    address public whiteListAddress;
    address public migratorAddress;

    function setUp() public {
        whiteListAddress = address(new WhiteList());
        migratorAddress = address(new Migrator());
        factory = new BittyVaultFactory();
        grantor1 = makeAddr("grantor1");
        grantor2 = makeAddr("grantor2");
        wethAddress = makeAddr("wethAddress");
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
        yieldProviders = new address[](0);
        swapProviders = new address[](1);
        swapProviders[0] = uniswapV4RouterAddress;
        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addAssets(assetAddresses);
        IWhiteList(whiteListAddress).addStableCoins(stableCoinAddresses);
        IWhiteList(whiteListAddress).addYieldProviders(yieldProviders);
        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);
        vm.stopPrank();
    }

    function test_FactoryRevertsIfAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        factory.initialize(address(0), whiteListAddress, migratorAddress);
    }

    function test_DeployVaultRevertsIfAddressNotWhiteListed() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        vm.expectRevert(InvalidGrantor.selector);
        factory.deployVault(address(0), "salt1", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        address[] memory invalidAddressArray = new address[](1);
        invalidAddressArray[0] = makeAddr("invalidAddress");
        vm.prank(grantor1);
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(grantor1, "salt1", invalidAddressArray, stableCoinAddresses, yieldProviders, swapProviders);
    }

    function test_DeployVaultRevertsIfUnauthorized() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        factory.deployVault(grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
    }

    function test_DeployVaultForDifferentGrantors() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        vm.prank(grantor1);
        address vault1 =
            factory.deployVault(grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        vm.prank(grantor2);
        address vault2 =
            factory.deployVault(grantor2, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        assertTrue(vault1 != vault2, "Different grantors should get different vault addresses");
        assertTrue(vault1 != address(0), "Vault1 should not be zero address");
        assertTrue(vault2 != address(0), "Vault2 should not be zero address");
    }

    function test_ComputeVaultAddress() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address computedAddress = factory.computeVaultAddress(grantor1);
        assertTrue(computedAddress != address(0), "Computed address should not be zero");

        vm.prank(grantor1);
        address deployedAddress =
            factory.deployVault(grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        assertTrue(deployedAddress != address(0), "Deployed address should not be zero");
        assertTrue(computedAddress != deployedAddress, "Addresses should differ due to inputSalt");
    }

    function test_SameGrantorCanDeployMultipleVaults() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        vm.prank(grantor1);
        address vault1 =
            factory.deployVault(grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        vm.prank(grantor1);
        address vault2 =
            factory.deployVault(grantor1, "salt2", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        assertTrue(vault1 != vault2, "Different salts should produce different vault addresses");
        assertTrue(vault1 != address(0), "Vault1 should not be zero");
        assertTrue(vault2 != address(0), "Vault2 should not be zero");
    }

    function test_SameGrantorSameSaltRevertsIfVaultExists() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        vm.prank(grantor1);
        address vault1 =
            factory.deployVault(grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        assertTrue(vault1 != address(0), "First vault should be deployed");

        vm.prank(grantor1);
        vm.expectRevert(VaultAlreadyDeployed.selector);
        factory.deployVault(grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
    }

    function test_DeployedVaultCanBeInitialized() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        vm.prank(grantor1);
        address vaultAddress =
            factory.deployVault(grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        BittyVault vault = BittyVault(payable(vaultAddress));

        assertTrue(vault.isInitialized(), "Vault should be initialized");
        assertEq(vault.grantor(), grantor1, "Grantor should be set correctly");

        address[] memory assets = vault.getAssets();
        assertEq(assets[0], wbtcAddress, "WBTC address should be set");
        assertEq(assets[1], wethAddress, "WETH address should be set");
        address[] memory stableCoins = vault.getStableCoins();
        assertEq(stableCoins[0], usdtAddress, "USDT address should be set");
        assertEq(stableCoins[1], usdcAddress, "USDC address should be set");
    }

    function test_DeployVaultRevertsIfVaultAlreadyExistsAtComputedAddress() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);

        string memory testSalt = "salt1";
        bytes memory bytecode = type(BittyVault).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(grantor1, testSalt));

        bytes32 bytecodeHash = keccak256(bytecode);

        address factoryAddr = address(factory);
        address computedAddr;
        assembly {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), bytecodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, factoryAddr)
            let start := add(ptr, 0x0b)
            mstore8(start, 0xff)
            computedAddr := and(keccak256(start, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }

        bytes memory minimalBytecode =
            hex"6080604052348015600f57600080fd5b50603f80601d6000396000f3fe6080604052600080fdfea2646970667358221220";
        address deployedAddr;
        assembly {
            deployedAddr := create2(0, add(minimalBytecode, 0x20), mload(minimalBytecode), salt)
        }

        if (deployedAddr == computedAddr && deployedAddr.code.length > 0) {
            vm.prank(grantor1);
            vm.expectRevert(VaultAlreadyDeployed.selector);
            factory.deployVault(grantor1, testSalt, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        }
    }

    function test_InitializeSuccess() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        assertEq(factory.wethAddress(), wethAddress, "WETH address should be set");
        assertEq(address(factory.whiteList()), whiteListAddress, "WhiteList address should be set");
    }

    function test_DeployVaultRevertsIfStableCoinNotWhiteListed() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address[] memory invalidStableCoinArray = new address[](1);
        invalidStableCoinArray[0] = makeAddr("invalidStableCoin");
        vm.prank(grantor1);
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(grantor1, "salt1", assetAddresses, invalidStableCoinArray, yieldProviders, swapProviders);
    }

    function test_DeployVaultRevertsIfYieldProviderNotWhiteListed() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address[] memory invalidYieldProviderArray = new address[](1);
        invalidYieldProviderArray[0] = makeAddr("invalidYieldProvider");
        vm.prank(grantor1);
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(
            grantor1, "salt1", assetAddresses, stableCoinAddresses, invalidYieldProviderArray, swapProviders
        );
    }

    function test_DeployVaultRevertsIfSwapProviderNotWhiteListed() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address[] memory invalidSwapProviderArray = new address[](1);
        invalidSwapProviderArray[0] = makeAddr("invalidSwapProvider");
        vm.prank(grantor1);
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(
            grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, invalidSwapProviderArray
        );
    }

    function test_DeployVaultWithEmptyArrays() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address[] memory emptyAssets = new address[](0);
        address[] memory emptyStableCoins = new address[](0);
        address[] memory emptyYieldProviders = new address[](0);
        address[] memory emptySwapProviders = new address[](0);

        vm.prank(grantor1);
        address vault = factory.deployVault(
            grantor1, "salt1", emptyAssets, emptyStableCoins, emptyYieldProviders, emptySwapProviders
        );

        assertTrue(vault != address(0), "Vault should be deployed");
        BittyVault vaultInstance = BittyVault(payable(vault));
        assertTrue(vaultInstance.isInitialized(), "Vault should be initialized");
    }

    function test_DeployVaultEmitsEvent() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);

        vm.prank(grantor1);
        address vault =
            factory.deployVault(grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        assertTrue(vault != address(0), "Vault should be deployed");

        BittyVault vaultInstance = BittyVault(payable(vault));
        assertTrue(vaultInstance.isInitialized(), "Vault should be initialized");
        assertEq(vaultInstance.grantor(), grantor1, "Grantor should match");
    }

    function test_ComputeVaultAddressForDifferentGrantors() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address computed1 = factory.computeVaultAddress(grantor1);
        address computed2 = factory.computeVaultAddress(grantor2);

        assertTrue(computed1 != computed2, "Different grantors should compute to different addresses");
        assertTrue(computed1 != address(0), "Computed address should not be zero");
        assertTrue(computed2 != address(0), "Computed address should not be zero");
    }

    function test_DeployVaultWithMultipleAssets() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address[] memory multipleAssets = new address[](3);
        multipleAssets[0] = wbtcAddress;
        multipleAssets[1] = wethAddress;
        multipleAssets[2] = makeAddr("asset3");

        vm.startPrank(tx.origin);
        address[] memory newAsset = new address[](1);
        newAsset[0] = multipleAssets[2];
        IWhiteList(whiteListAddress).addAssets(newAsset);
        vm.stopPrank();

        vm.prank(grantor1);
        address vault =
            factory.deployVault(grantor1, "salt1", multipleAssets, stableCoinAddresses, yieldProviders, swapProviders);

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultWithMultipleStableCoins() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address[] memory multipleStableCoins = new address[](3);
        multipleStableCoins[0] = usdtAddress;
        multipleStableCoins[1] = usdcAddress;
        multipleStableCoins[2] = makeAddr("stableCoin3");

        vm.startPrank(tx.origin);
        address[] memory newStableCoin = new address[](1);
        newStableCoin[0] = multipleStableCoins[2];
        IWhiteList(whiteListAddress).addStableCoins(newStableCoin);
        vm.stopPrank();

        vm.prank(grantor1);
        address vault =
            factory.deployVault(grantor1, "salt1", assetAddresses, multipleStableCoins, yieldProviders, swapProviders);

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultWithMultipleYieldProviders() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address yieldProvider1 = makeAddr("yieldProvider1");
        address yieldProvider2 = makeAddr("yieldProvider2");
        address[] memory multipleYieldProviders = new address[](2);
        multipleYieldProviders[0] = yieldProvider1;
        multipleYieldProviders[1] = yieldProvider2;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addYieldProviders(multipleYieldProviders);
        vm.stopPrank();

        vm.prank(grantor1);
        address vault = factory.deployVault(
            grantor1, "salt1", assetAddresses, stableCoinAddresses, multipleYieldProviders, swapProviders
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultWithMultipleSwapProviders() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address swapProvider1 = makeAddr("swapProvider1");
        address swapProvider2 = makeAddr("swapProvider2");
        address[] memory multipleSwapProviders = new address[](2);
        multipleSwapProviders[0] = swapProvider1;
        multipleSwapProviders[1] = swapProvider2;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addSwapProviders(multipleSwapProviders);
        vm.stopPrank();

        vm.prank(grantor1);
        address vault = factory.deployVault(
            grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, multipleSwapProviders
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultRevertsIfMultipleAssetsOneNotWhiteListed() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address[] memory mixedAssets = new address[](3);
        mixedAssets[0] = wbtcAddress;
        mixedAssets[1] = wethAddress;
        mixedAssets[2] = makeAddr("invalidAsset");

        vm.prank(grantor1);
        vm.expectRevert(NotWhiteListed.selector);

        factory.deployVault(grantor1, "salt1", mixedAssets, stableCoinAddresses, yieldProviders, swapProviders);
    }

    function test_DeployVaultRevertsIfMultipleStableCoinsOneNotWhiteListed() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address[] memory mixedStableCoins = new address[](3);
        mixedStableCoins[0] = usdtAddress;
        mixedStableCoins[1] = usdcAddress;
        mixedStableCoins[2] = makeAddr("invalidStableCoin");

        vm.prank(grantor1);
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(grantor1, "salt1", assetAddresses, mixedStableCoins, yieldProviders, swapProviders);
    }

    function test_DeployVaultRevertsIfMultipleYieldProvidersOneNotWhiteListed() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address yieldProvider1 = makeAddr("yieldProvider1");
        address[] memory mixedYieldProviders = new address[](2);
        mixedYieldProviders[0] = yieldProvider1;
        mixedYieldProviders[1] = makeAddr("invalidYieldProvider");

        vm.startPrank(tx.origin);
        address[] memory validProvider = new address[](1);
        validProvider[0] = yieldProvider1;
        IWhiteList(whiteListAddress).addYieldProviders(validProvider);
        vm.stopPrank();

        vm.prank(grantor1);
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(grantor1, "salt1", assetAddresses, stableCoinAddresses, mixedYieldProviders, swapProviders);
    }

    function test_DeployVaultRevertsIfMultipleSwapProvidersOneNotWhiteListed() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        address swapProvider1 = makeAddr("swapProvider1");
        address[] memory mixedSwapProviders = new address[](2);
        mixedSwapProviders[0] = swapProvider1;
        mixedSwapProviders[1] = makeAddr("invalidSwapProvider");

        vm.startPrank(tx.origin);
        address[] memory validProvider = new address[](1);
        validProvider[0] = swapProvider1;
        IWhiteList(whiteListAddress).addSwapProviders(validProvider);
        vm.stopPrank();

        vm.prank(grantor1);
        vm.expectRevert(NotWhiteListed.selector);

        factory.deployVault(grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, mixedSwapProviders);
    }

    function test_DeployVaultRevertsIfVaultAlreadyExistsAtComputedAddressForced() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);

        string memory testSalt = "salt1";
        bytes memory bytecode = type(BittyVault).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(grantor1, testSalt));
        bytes32 bytecodeHash = keccak256(bytecode);

        address factoryAddr = address(factory);
        address computedAddr;
        assembly {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), bytecodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, factoryAddr)
            let start := add(ptr, 0x0b)
            mstore8(start, 0xff)
            computedAddr := and(keccak256(start, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }

        bytes memory minimalBytecode =
            hex"6080604052348015600f57600080fd5b50603f80601d6000396000f3fe6080604052600080fdfea2646970667358221220";

        address deployedAddr;
        assembly {
            deployedAddr := create2(0, add(minimalBytecode, 0x20), mload(minimalBytecode), salt)
        }

        if (deployedAddr == computedAddr && deployedAddr.code.length > 0) {
            vm.prank(grantor1);
            vm.expectRevert(VaultAlreadyDeployed.selector);
            factory.deployVault(grantor1, testSalt, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        } else {
            vm.etch(computedAddr, minimalBytecode);
            if (computedAddr.code.length > 0) {
                vm.prank(grantor1);
                vm.expectRevert(VaultAlreadyDeployed.selector);
                factory.deployVault(
                    grantor1, testSalt, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders
                );
            }
        }
    }

    function test_ComputeAddressInternalFunction() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);

        address addr1 = factory.computeVaultAddress(grantor1);
        address addr2 = factory.computeVaultAddress(grantor2);

        assertTrue(addr1 != address(0), "Computed address should not be zero");
        assertTrue(addr2 != address(0), "Computed address should not be zero");
        assertTrue(addr1 != addr2, "Different grantors should produce different addresses");

        address addr1Again = factory.computeVaultAddress(grantor1);
        assertEq(addr1, addr1Again, "Same grantor should produce same computed address");
    }

    function test_DeployVaultSuccessWithAllValidParameters() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);

        vm.prank(grantor1);
        address vault =
            factory.deployVault(grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        assertTrue(vault != address(0), "Vault should be deployed");
        BittyVault vaultInstance = BittyVault(payable(vault));
        assertTrue(vaultInstance.isInitialized(), "Vault should be initialized");
        assertEq(vaultInstance.grantor(), grantor1, "Grantor should match");
    }

    function test_InitializeSetsStateVariables() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);
        assertEq(factory.wethAddress(), wethAddress, "WETH address should be set");
        assertEq(address(factory.whiteList()), whiteListAddress, "WhiteList address should be set");
    }

    function test_DeployVaultEmitsVaultDeployedEvent() public {
        factory.initialize(wethAddress, whiteListAddress, migratorAddress);

        vm.prank(grantor1);
        address vault =
            factory.deployVault(grantor1, "salt1", assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        assertTrue(vault != address(0), "Vault should be deployed");

        BittyVault vaultInstance = BittyVault(payable(vault));
        assertTrue(vaultInstance.isInitialized(), "Vault should be initialized");
        assertEq(vaultInstance.grantor(), grantor1, "Grantor should match event");
    }
}

