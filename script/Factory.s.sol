// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {Factory} from "../src/Factory.sol";
import {Vault} from "../src/Vault.sol";
import {console2} from "forge-std/console2.sol";
import {DeployScript} from "./BaseDeploy.sol";

contract FactoryScript is DeployScript {
    Factory public factory;

    function deploy() public override {
        Vault vaultImplementation = new Vault();
        console2.log("Vault implementation deployed at", address(vaultImplementation));
        factory = new Factory();
        console2.log("Factory deployed at", address(factory));

        address whiteList = getAddress("WHITE_LIST");
        address weth = getAddress("WETH");
        factory.initialize(address(vaultImplementation), whiteList, weth);

        saveAddress("VAULT_FACTORY", address(factory));
    }
}
