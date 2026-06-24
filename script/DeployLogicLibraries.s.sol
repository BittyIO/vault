// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {VaultLogic} from "../src/logic/VaultLogic.sol";
import {AssetManagerLogic} from "../src/logic/AssetManagerLogic.sol";
import {BittyVault} from "../src/BittyVault.sol";

/// @notice Deploys VaultLogic, AssetManagerLogic, and BittyVault via the
/// canonical deterministic CREATE2 deployer (salt = 0), so they land at the
/// same address on every EVM chain.
contract DeployLogicLibraries is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant SALT = bytes32(0);

    address constant VAULT_LOGIC = 0xFb20542A2FeA887578D598e102e14D0E86db8291;
    address constant ASSET_MANAGER_LOGIC = 0x93cc0FcF2D8EddB6a9Be480b7A7BaAFa07D9Af4F;
    address constant VAULT_IMPLEMENTATION = 0x2E14D540D41AdF746e54B5FD259BA93666A4DE00;

    function run() public {
        vm.startBroadcast();

        _deploy("VaultLogic", type(VaultLogic).creationCode, VAULT_LOGIC);
        _deploy("AssetManagerLogic", type(AssetManagerLogic).creationCode, ASSET_MANAGER_LOGIC);
        _deploy("BittyVault", type(BittyVault).creationCode, VAULT_IMPLEMENTATION);

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
