// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {VaultLogic} from "../src/logic/VaultLogic.sol";
import {AssetManagerLogic} from "../src/logic/AssetManagerLogic.sol";

/// @notice Deploys the VaultLogic and AssetManagerLogic libraries via the
/// canonical deterministic CREATE2 deployer (salt = 0), at the addresses
/// already linked into the deployed BittyVault implementation
/// (0x670e6F8144f11D7930b6a4797ed6595A7238A1D2). These library deployments
/// were prepared but never confirmed during the original mainnet deploy.
contract DeployLogicLibraries is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant SALT = bytes32(0);

    address constant VAULT_LOGIC = 0x34B12C466A49Ebc0f77Ec4648dE63f1D1C18786B;
    address constant ASSET_MANAGER_LOGIC = 0x2325AE2429e3B43650c6D3f1D7bB13cAdC6d8dee;

    function run() public {
        vm.startBroadcast();

        _deploy("VaultLogic", type(VaultLogic).creationCode, VAULT_LOGIC);
        _deploy("AssetManagerLogic", type(AssetManagerLogic).creationCode, ASSET_MANAGER_LOGIC);

        vm.stopBroadcast();
    }

    function _deploy(string memory name, bytes memory creationCode, address expected) internal {
        if (expected.code.length > 0) {
            console2.log(name, "already deployed at", expected);
            return;
        }
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(SALT, creationCode));
        require(ok && ret.length == 20, "CREATE2 deploy failed");
        address deployed = address(bytes20(ret));
        require(deployed == expected, "unexpected library address");
        console2.log(name, "deployed at", deployed);
    }
}
