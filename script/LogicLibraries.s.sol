// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {Create2Deployer} from "./Create2Deployer.sol";
import {VaultLogic as VaultLogicImplementation} from "../src/logic/VaultLogic.sol";
import {AssetManagerLogic as AssetManagerLogicImplementation} from "../src/logic/AssetManagerLogic.sol";
import {AssetManagerTradeLogic as AssetManagerTradeLogicImplementation} from "../src/logic/AssetManagerTradeLogic.sol";

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
/// Yield + config + protocol registration. Standalone (no `--libraries` flag needed).
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

/// @notice Step 1c — deploy AssetManagerTradeLogic via CREATE2 (salt = 0).
///
/// The asset manager's trading surface (market/AMM/intent/TWAP). Run after step 1a — it links
/// against VaultLogic, so pass its CREATE2 address:
///
/// Usage:
///   source .env
///   forge script script/LogicLibraries.s.sol:AssetManagerTradeLogic \
///     --rpc-url sepolia \
///     --broadcast \
///     --private-key $SEPOLIA_PRIVATE_KEY \
///     --libraries src/logic/VaultLogic.sol:VaultLogic:{VAULT_LOGIC} \
///     -vvvv
contract AssetManagerTradeLogic is DeployScript, Create2Deployer {
    function deploy() public override {
        address assetManagerTradeLogic =
            _deployCreate2("AssetManagerTradeLogic", type(AssetManagerTradeLogicImplementation).creationCode);
        saveAddress("ASSET_MANAGER_TRADE_LOGIC", assetManagerTradeLogic);
    }
}
