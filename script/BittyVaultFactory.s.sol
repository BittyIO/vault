// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {BittyVaultFactory} from "../src/BittyVaultFactory.sol";
import {DeployScript} from "./BaseDeploy.sol";
import {BittyVault} from "../src/BittyVault.sol";
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

    bytes32 salt = 0x00000000000000000000000000000000000000007179c0ee83ea00004ee6b1e9;

    function deploy() public override {
        bytes memory initCode = type(BittyVaultFactory).creationCode;

        address factoryAddress = factory.safeCreate2(salt, initCode);

        address guard = getAddress("BITTY_GUARD");
        address weth = getAddress("WETH");

        BittyVault vaultImplementation = new BittyVault();

        saveAddress("VAULT_IMPLEMENTATION", address(vaultImplementation));

        BittyVaultFactory(factoryAddress).initialize(address(vaultImplementation), guard, weth);

        console2.log(factoryAddress);

        saveAddress("BITTY_VAULT_FACTORY", factoryAddress);
    }
}
