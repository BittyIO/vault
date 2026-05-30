// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {Factory} from "../src/Factory.sol";
import {DeployScript} from "./BaseDeploy.sol";
import {Vault} from "../src/Vault.sol";
import {console2} from "forge-std/console2.sol";

interface ImmutableCreate2Factory {
    function safeCreate2(bytes32 salt, bytes calldata initCode) external payable returns (address deploymentAddress);
    function findCreate2Address(bytes32 salt, bytes calldata initCode) external view returns (address deploymentAddress);
    function findCreate2AddressViaHash(bytes32 salt, bytes32 initCodeHash)
        external
        view
        returns (address deploymentAddress);
}

contract Deploy is DeployScript {
    ImmutableCreate2Factory immutable factory = ImmutableCreate2Factory(0x0000000000FFe8B47B3e2130213B802212439497);

    bytes32 salt = 0x0000000000000000000000000000000000000000ac49527ab26c30000a359528;

    function deploy() public override {
        bytes memory initCode = type(Factory).creationCode;

        address factoryAddress = factory.safeCreate2(salt, initCode);

        address whiteList = getAddress("WHITE_LIST");
        address subscription = getAddress("SUBSCRIPTION");
        address weth = getAddress("WETH");

        Vault vaultImplementation = new Vault();

        Factory(factoryAddress).initialize(address(vaultImplementation), whiteList, subscription, weth);

        console2.log(factoryAddress);

        saveAddress("FACTORY", factoryAddress);
    }
}
