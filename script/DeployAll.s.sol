// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {BittyV1Vault} from "../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1VaultFactory} from "../src/BittyV1VaultFactory.sol";

interface ImmutableCreate2Factory {
    function safeCreate2(bytes32 salt, bytes calldata initCode) external payable returns (address);
    function findCreate2Address(bytes32 salt, bytes calldata initCode) external view returns (address);
}

/**
 * @notice One-shot deploy of the whole vault stack. forge deploys and links the logic libraries
 *         (VaultLogic, AssetManagerLogic) automatically as part of the broadcast,
 *         so this script only deploys the implementation, the DeFi facet, and the factory — then wires the
 *         factory to them. `--libraries` is NOT needed to deploy; pass it only when verifying on Etherscan.
 *
 *   source .env
 *   forge script script/DeployAll.s.sol:DeployAll \
 *     --rpc-url sepolia --broadcast --private-key $SEPOLIA_PRIVATE_KEY -vvvv
 *
 * Prerequisites in deployments/<chain>.toml: BITTY_GUARD and WETH. The broadcasting key MUST be the
 * factory's baked-in DEPLOYER (0x12EE2de7BF086388B1D560eb95e7191Edfab9823) — factory.initialize gates on
 * tx.origin. Re-running is safe: the factory is only deployed/initialized if it isn't already.
 */
contract DeployAll is DeployScript {
    // Keyless CREATE2 factory (same address on every chain) — gives the factory a deterministic address.
    ImmutableCreate2Factory constant IMMUTABLE_CREATE2 =
        ImmutableCreate2Factory(0x0000000000FFe8B47B3e2130213B802212439497);
    bytes32 constant FACTORY_SALT = 0x12ee2de7bf086388b1d560eb95e7191edfab9823113581c4eea640003b0e193e;

    function deploy() public override {
        // Implementation + DeFi facet. The logic libraries they depend on are auto-deployed + linked by
        // forge before these lines run, so there's nothing to do here for them.
        BittyV1Vault vaultImpl = new BittyV1Vault();
        BittyV1VaultDeFiFacet defiFacet = new BittyV1VaultDeFiFacet();
        saveAddress("VAULT_IMPLEMENTATION", address(vaultImpl));
        saveAddress("DEFI_FACET", address(defiFacet));
        console2.log("BittyV1Vault implementation", address(vaultImpl));
        console2.log("BittyV1VaultDeFiFacet      ", address(defiFacet));

        // Factory at its deterministic address via the keyless ImmutableCreate2Factory, then a one-time
        // initialize pointing at the impl/facet and the guard/weth from deployments/<chain>.toml.
        bytes memory factoryInit = type(BittyV1VaultFactory).creationCode;
        address factory = IMMUTABLE_CREATE2.findCreate2Address(FACTORY_SALT, factoryInit);
        if (factory.code.length == 0) {
            factory = IMMUTABLE_CREATE2.safeCreate2(FACTORY_SALT, factoryInit);
            console2.log("BittyV1VaultFactory deployed at       ", factory);
        } else {
            console2.log("BittyV1VaultFactory already deployed at", factory);
        }
        if (BittyV1VaultFactory(factory).vaultImplementation() == address(0)) {
            BittyV1VaultFactory(factory)
                .initialize(address(vaultImpl), address(defiFacet), getAddress("BITTY_GUARD"), getAddress("WETH"));
        }
        saveAddress("BITTY_VAULT_FACTORY", factory);
        console2.log("BittyV1VaultFactory            ", factory);
    }
}
