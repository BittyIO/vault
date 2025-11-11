// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {BittyVaultFactory} from "../src/BittyVaultFactory.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";
import {mainnet, sepolia} from "../script/addresses.sol";

contract BittyVaultFactoryScript is Script {
    BittyVaultFactory public factory;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        factory = new BittyVaultFactory();
        factory.initialize(
            getWETHAddress(),
            getWBTCAddress(),
            getUSDTAddress(),
            getUSDCAddress(),
            getAAVEV3Address(),
            getUniswapV4RouterAddress()
        );

        address grantor = vm.envOr("GRANTOR_ADDRESS", msg.sender);

        address vaultAddress = factory.deployVault(grantor);

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
