// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "lib/forge-std/src/Script.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {BittyVaultFactory} from "../src/BittyVaultFactory.sol";
import {mainnet, sepolia} from "../script/addresses.sol";
import {console2} from "lib/forge-std/src/console2.sol";

contract BittyVaultFactoryScript is Script {
    BittyVaultFactory public factory;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        factory = new BittyVaultFactory();
        address whiteListAddress = getWhiteListAddress();
        address migratorAddress = getMigratorAddress();
        factory.initialize(getWETHAddress(), whiteListAddress, migratorAddress);

        vm.stopBroadcast();
        console2.log(address(factory));
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

    function getWhiteListAddress() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return mainnet.WHITE_LIST;
        } else if (chainId == 11155111) {
            return sepolia.WHITE_LIST;
        }
        return address(0);
    }

    function getMigratorAddress() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return mainnet.MIGRATOR;
        } else if (chainId == 11155111) {
            return sepolia.MIGRATOR;
        }
        return address(0);
    }
}
