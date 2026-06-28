// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {Create2Deployer} from "./Create2Deployer.sol";
import {VaultLogic as VaultLogicImplementation} from "../src/logic/VaultLogic.sol";
import {AssetManagerLogic as AssetManagerLogicImplementation} from "../src/logic/AssetManagerLogic.sol";

/// @notice Step 1a — deploy VaultLogic via CREATE2 (salt = 0).
///
/// Run this first, without any `--libraries` flag.
///
/// Usage:
///   source .env
///   forge script script/LogicLibraries.s.sol:VaultLogic \
///     --rpc-url sepolia \
///     --broadcast \
///     --private-key $SEPOLIA_PRIVATE_KEY \
///     -vvvv
contract VaultLogic is DeployScript, Create2Deployer {
    function deploy() public override {
        address vaultLogic = _deployCreate2("VaultLogic", type(VaultLogicImplementation).creationCode);
        saveAddress("VAULT_LOGIC", vaultLogic);
    }
}

/// @notice Step 1b — deploy AssetManagerLogic via CREATE2 (salt = 0).
///
/// Run after step 1a. AssetManagerLogic links against VaultLogic.
///
/// Usage:
///   source .env
///   forge script script/LogicLibraries.s.sol:AssetManagerLogic \
///     --rpc-url sepolia \
///     --broadcast \
///     --private-key $SEPOLIA_PRIVATE_KEY \
///     -vvvv
contract AssetManagerLogic is DeployScript, Create2Deployer {
    function deploy() public override {
        address assetManagerLogic =
            _deployCreate2("AssetManagerLogic", type(AssetManagerLogicImplementation).creationCode);
        saveAddress("ASSET_MANAGER_LOGIC", assetManagerLogic);
    }
}
