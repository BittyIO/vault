// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {BittyVaultFactory} from "../src/BittyVaultFactory.sol";

interface ImmutableCreate2Factory {
    function safeCreate2(bytes32 salt, bytes calldata initCode) external payable returns (address deploymentAddress);
    function findCreate2Address(bytes32 salt, bytes calldata initCode) external view returns (address deploymentAddress);
}

/// @notice Step 3 — deploy and initialize BittyVaultFactory via ImmutableCreate2Factory.
///
/// Requires `VAULT_IMPLEMENTATION`, `BITTY_GUARD`, and `WETH` in `deployments/<chain>.toml`.
///
/// Usage:
///   source .env
///   forge script script/DeployBittyVaultFactory.s.sol:Deploy \
///     --rpc-url sepolia \
///     --broadcast \
///     --private-key $SEPOLIA_PRIVATE_KEY \
///     -vvvv
contract Deploy is DeployScript {
    ImmutableCreate2Factory constant IMMUTABLE_CREATE2 =
        ImmutableCreate2Factory(0x0000000000FFe8B47B3e2130213B802212439497);
    bytes32 constant FACTORY_SALT = 0x0000000000000000000000000000000000000000e3b8e27e256a40000b2b5a1c;

    function deploy() public override {
        address vaultImpl = getAddress("VAULT_IMPLEMENTATION");

        bytes memory factoryInitCode = type(BittyVaultFactory).creationCode;
        address factoryAddr = IMMUTABLE_CREATE2.findCreate2Address(FACTORY_SALT, factoryInitCode);
        if (factoryAddr.code.length == 0) {
            factoryAddr = IMMUTABLE_CREATE2.safeCreate2(FACTORY_SALT, factoryInitCode);
        } else {
            console2.log("BittyVaultFactory already deployed at", factoryAddr);
        }

        BittyVaultFactory factory = BittyVaultFactory(factoryAddr);
        if (factory.vaultImplementation() == address(0)) {
            factory.initialize(vaultImpl, getAddress("BITTY_GUARD"), getAddress("WETH"));
        }

        console2.log("BittyVaultFactory deployed at", factoryAddr);
        saveAddress("BITTY_VAULT_FACTORY", factoryAddr);
    }
}
