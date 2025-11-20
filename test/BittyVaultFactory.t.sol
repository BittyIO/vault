// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVaultFactory} from "../src/BittyVaultFactory.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {AssetManager} from "../src/AssetManager.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";
import {InvalidGrantor, AddressZero} from "../src/interfaces/Errors.sol";

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

    function setUp() public {
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
    }

    function test_FactoryRevertsIfAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        factory.initialize(address(0), assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        address[] memory invalidAddressArray = new address[](1);
        invalidAddressArray[0] = address(0);
        vm.expectRevert(AddressZero.selector);
        factory.initialize(wethAddress, invalidAddressArray, stableCoinAddresses, yieldProviders, swapProviders);
        vm.expectRevert(AddressZero.selector);
        factory.initialize(wethAddress, assetAddresses, invalidAddressArray, yieldProviders, swapProviders);
        vm.expectRevert(AddressZero.selector);
        factory.initialize(wethAddress, assetAddresses, stableCoinAddresses, invalidAddressArray, swapProviders);
        vm.expectRevert(AddressZero.selector);
        factory.initialize(wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, invalidAddressArray);
    }

    function test_DeployVaultRevertsIfAddressZero() public {
        factory.initialize(wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        vm.expectRevert(InvalidGrantor.selector);
        factory.deployVault(address(0), wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        vm.expectRevert(AddressZero.selector);
        factory.deployVault(grantor1, address(0), assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        address[] memory invalidAddressArray = new address[](1);
        invalidAddressArray[0] = address(0);
        vm.expectRevert(AddressZero.selector);
        factory.deployVault(
            grantor1, wethAddress, invalidAddressArray, stableCoinAddresses, yieldProviders, swapProviders
        );
        vm.expectRevert(AddressZero.selector);
        factory.deployVault(grantor1, wethAddress, assetAddresses, invalidAddressArray, yieldProviders, swapProviders);
        vm.expectRevert(AddressZero.selector);
        factory.deployVault(
            grantor1, wethAddress, assetAddresses, stableCoinAddresses, invalidAddressArray, swapProviders
        );
        vm.expectRevert(AddressZero.selector);
        factory.deployVault(
            grantor1, wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, invalidAddressArray
        );
    }

    function test_DeployVaultForDifferentGrantors() public {
        factory.initialize(wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        address vault1 = factory.deployVault(
            grantor1, wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders
        );
        address vault2 = factory.deployVault(
            grantor2, wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders
        );

        assertTrue(vault1 != vault2, "Different grantors should get different vault addresses");
        assertTrue(vault1 != address(0), "Vault1 should not be zero address");
        assertTrue(vault2 != address(0), "Vault2 should not be zero address");
    }

    function test_ComputeVaultAddress() public {
        factory.initialize(wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        address computedAddress = factory.computeVaultAddress(grantor1);
        address deployedAddress = factory.deployVault(
            grantor1, wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders
        );

        assertEq(computedAddress, deployedAddress, "Computed address should match deployed address");
    }

    function test_SameGrantorGetsSameAddress() public {
        factory.initialize(wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        address vault1 = factory.deployVault(
            grantor1, wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders
        );

        address computedAddress = factory.computeVaultAddress(grantor1);
        assertEq(vault1, computedAddress, "Same grantor should compute to same address");
    }

    function test_DeployedVaultCanBeInitialized() public {
        factory.initialize(wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        address vaultAddress = factory.deployVault(
            grantor1, wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders
        );
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

    function test_MultipleVaultsForSameGrantor() public {
        factory.initialize(wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        address vault1 = factory.deployVault(
            grantor1, wethAddress, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders
        );
        address computed = factory.computeVaultAddress(grantor1);
        assertEq(vault1, computed, "Address should be deterministic");
    }
}

