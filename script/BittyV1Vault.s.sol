// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {Create2Deployer} from "./Create2Deployer.sol";
import {BittyV1Vault as BittyV1VaultImplementation} from "../src/BittyV1Vault.sol";

/// @notice Step 2 — deploy the BittyV1Vault implementation via CREATE2 (salt = 0).
///
/// BittyV1Vault links against both logic libraries. Pass their CREATE2 addresses
/// (from step 1 / `deployments/<chain>.toml`) when compiling this script:
///
///   --libraries src/logic/VaultLogic.sol:VaultLogic:0xDb4FCe915F33e804279102Ce8dd3ffC449A51cfe
///   --libraries src/logic/AssetManagerLogic.sol:AssetManagerLogic:0x2FEaCA063F6F2169bd3931D25f02A2Ab264fe1A0
///
/// Usage:
///   source .env
///   forge script script/BittyV1Vault.s.sol:BittyV1Vault \
///     --rpc-url sepolia \
///     --broadcast \
///     --private-key $SEPOLIA_PRIVATE_KEY \
///     --libraries src/logic/VaultLogic.sol:VaultLogic:0xDb4FCe915F33e804279102Ce8dd3ffC449A51cfe \
///     --libraries src/logic/AssetManagerLogic.sol:AssetManagerLogic:0x2FEaCA063F6F2169bd3931D25f02A2Ab264fe1A0 \
///     -vvvv
contract BittyV1Vault is DeployScript, Create2Deployer {
    function deploy() public override {
        address vaultImpl = _deployCreate2("BittyV1Vault", type(BittyV1VaultImplementation).creationCode);
        saveAddress("VAULT_IMPLEMENTATION", vaultImpl);
    }
}
