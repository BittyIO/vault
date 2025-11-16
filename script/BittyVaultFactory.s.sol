// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "lib/forge-std/src/Script.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {BittyVaultFactory} from "../src/BittyVaultFactory.sol";
import {mainnet, sepolia} from "../script/addresses.sol";

contract BittyVaultFactoryScript is Script {
    BittyVaultFactory public factory;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        factory = new BittyVaultFactory();
        address[] memory assetAddresses = new address[](2);
        assetAddresses[0] = getWBTCAddress();
        assetAddresses[1] = getWETHAddress();
        address[] memory stableCoinAddresses = new address[](2);
        stableCoinAddresses[0] = getUSDTAddress();
        stableCoinAddresses[1] = getUSDCAddress();
        address[] memory yieldProviders = new address[](0);
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = getUniswapV4RouterAddress();
        factory.initialize(getWETHAddress(), assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        address grantor = vm.envOr("GRANTOR_ADDRESS", msg.sender);

        address vaultAddress = factory.deployVault(
            grantor, getWETHAddress(), assetAddresses, stableCoinAddresses, yieldProviders, swapProviders
        );

        address computedAddress = factory.computeVaultAddress(grantor);
        require(vaultAddress == computedAddress, "Address mismatch");

        vm.stopBroadcast();
    }

    function getWETHAddress() internal view returns (address) {
        uint256 chainId = block.chainid;

        if (chainId == 1) {
            return mainnet.WETH;
        } else if (chainId == 11155111) {
            return sepolia.WETH;
        }
        return address(0);
    }

    function getWBTCAddress() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return mainnet.WBTC;
        } else if (chainId == 11155111) {
            return sepolia.WBTC;
        }
        return address(0);
    }

    function getUSDTAddress() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return mainnet.USDT;
        } else if (chainId == 11155111) {
            return sepolia.USDT;
        }
        return address(0);
    }

    function getUSDCAddress() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return mainnet.USDC;
        } else if (chainId == 11155111) {
            return sepolia.USDC;
        }
        return address(0);
    }

    function getAAVEV3Address() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return mainnet.AAVE_V3;
        } else if (chainId == 11155111) {
            return sepolia.AAVE_V3;
        }
        return address(0);
    }

    function getUniswapV4RouterAddress() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return mainnet.UNISWAP_V4_ROUTER;
        } else if (chainId == 11155111) {
            return sepolia.UNISWAP_V4_ROUTER;
        }
        return address(0);
    }
}
