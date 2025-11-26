// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVaultFactory} from "../src/BittyVaultFactory.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {AssetManager} from "../src/AssetManager.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";
import {InvalidGrantor, AddressZero, NotWhiteListed} from "../src/interfaces/Errors.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {IWhiteList} from "../src/interfaces/IWhiteList.sol";

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

    function setUp() public {
        whiteListAddress = address(new WhiteList());
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
        factory.initialize(address(0), whiteListAddress);
    }

    function test_DeployVaultRevertsIfAddressNotWhiteListed() public {
        factory.initialize(wethAddress, whiteListAddress);
        vm.expectRevert(InvalidGrantor.selector);
        factory.deployVault(address(0), assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        address[] memory invalidAddressArray = new address[](1);
        invalidAddressArray[0] = makeAddr("invalidAddress");
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(grantor1, invalidAddressArray, stableCoinAddresses, yieldProviders, swapProviders);
    }

    function test_DeployVaultForDifferentGrantors() public {
        factory.initialize(wethAddress, whiteListAddress);
        address vault1 =
            factory.deployVault(grantor1, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        address vault2 =
            factory.deployVault(grantor2, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        assertTrue(vault1 != vault2, "Different grantors should get different vault addresses");
        assertTrue(vault1 != address(0), "Vault1 should not be zero address");
        assertTrue(vault2 != address(0), "Vault2 should not be zero address");
    }

    function test_ComputeVaultAddress() public {
        factory.initialize(wethAddress, whiteListAddress);
        address computedAddress = factory.computeVaultAddress(grantor1);
        address deployedAddress =
            factory.deployVault(grantor1, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        assertEq(computedAddress, deployedAddress, "Computed address should match deployed address");
    }

    function test_SameGrantorGetsSameAddress() public {
        factory.initialize(wethAddress, whiteListAddress);
        address vault1 =
            factory.deployVault(grantor1, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        address computedAddress = factory.computeVaultAddress(grantor1);
        assertEq(vault1, computedAddress, "Same grantor should compute to same address");
    }

    function test_DeployedVaultCanBeInitialized() public {
        factory.initialize(wethAddress, whiteListAddress);
        address vaultAddress =
            factory.deployVault(grantor1, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
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
        factory.initialize(wethAddress, whiteListAddress);
        address vault1 =
            factory.deployVault(grantor1, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
        address computed = factory.computeVaultAddress(grantor1);
        assertEq(vault1, computed, "Address should be deterministic");
    }
}

