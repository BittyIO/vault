// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BittyVaultFactory} from "../src/BittyVaultFactory.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {console2} from "lib/forge-std/src/console2.sol";
import {DeployScript} from "./BaseDeploy.sol";

contract BittyVaultFactoryScript is DeployScript {
    BittyVaultFactory public factory;

    function deploy() public override {
        BittyVault vaultImplementation = new BittyVault();
        console2.log("Vault implementation deployed at", address(vaultImplementation));
        factory = new BittyVaultFactory();
        console2.log("Factory deployed at", address(factory));

        address whiteList = getAddress("WHITE_LIST");
        address weth = getAddress("WETH");
        factory.initialize(address(vaultImplementation), whiteList, weth);

        saveAddress("BITY_VAULT_FACTORY", address(factory));
    }
}
