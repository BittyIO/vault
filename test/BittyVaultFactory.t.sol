// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVaultFactory} from "../src/BittyVaultFactory.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {AssetType} from "../src/AssetManager.sol";

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
        factory.initialize(wethAddress, wbtcAddress, usdtAddress, usdcAddress, aaveV3Address, uniswapV4RouterAddress);
    }

    function test_DeployVaultForDifferentGrantors() public {
        address vault1 = factory.deployVault(grantor1);
        address vault2 = factory.deployVault(grantor2);

        assertTrue(vault1 != vault2, "Different grantors should get different vault addresses");
        assertTrue(vault1 != address(0), "Vault1 should not be zero address");
        assertTrue(vault2 != address(0), "Vault2 should not be zero address");
    }

    function test_ComputeVaultAddress() public {
        address computedAddress = factory.computeVaultAddress(grantor1);
        address deployedAddress = factory.deployVault(grantor1);

        assertEq(computedAddress, deployedAddress, "Computed address should match deployed address");
    }

    function test_SameGrantorGetsSameAddress() public {
        address vault1 = factory.deployVault(grantor1);

        address computedAddress = factory.computeVaultAddress(grantor1);
        assertEq(vault1, computedAddress, "Same grantor should compute to same address");
    }

    function test_DeployVaultRevertsOnZeroGrantor() public {
        vm.expectRevert(BittyVaultFactory.InvalidGrantor.selector);
        factory.deployVault(address(0));
    }

    function test_DeployedVaultCanBeInitialized() public {
        address vaultAddress = factory.deployVault(grantor1);
        BittyVault vault = BittyVault(payable(vaultAddress));

        assertTrue(vault.isInitialized(), "Vault should be initialized");
        assertEq(vault.grantor(), grantor1, "Grantor should be set correctly");

        assertEq(address(vault.assets(AssetType.WETH)), wethAddress, "WETH address should be set");
        assertEq(address(vault.assets(AssetType.WBTC)), wbtcAddress, "WBTC address should be set");
        assertEq(address(vault.assets(AssetType.USDT)), usdtAddress, "USDT address should be set");
        assertEq(address(vault.assets(AssetType.USDC)), usdcAddress, "USDC address should be set");
    }

    function test_MultipleVaultsForSameGrantor() public {
        address vault1 = factory.deployVault(grantor1);
        address computed = factory.computeVaultAddress(grantor1);
        assertEq(vault1, computed, "Address should be deterministic");
    }
}

