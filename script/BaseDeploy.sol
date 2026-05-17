// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {console2} from "forge-std/console2.sol";

abstract contract DeployScript is Script, Config {
    function deploy(string memory chainName) public {
        console2.log("Forking chain", chainName);
        vm.createSelectFork(chainName);
        string memory configPath = string.concat("./deployments/", chainName, ".toml");
        _loadConfig(configPath, true);
        vm.startBroadcast();
        deploy();
        vm.stopBroadcast();
    }

    function run() public {
        deploy(vm.getChain(block.chainid).name);
    }

    function getAddress(string memory key) public view returns (address) {
        address value = config.get(key).toAddress();
        require(value != address(0), string.concat("Address for key ", key, " not found"));
        return value;
    }

    function saveAddress(string memory key, address value) public {
        require(value != address(0), string.concat("Address for key ", key, " is 0x0"));
        config.set(key, value);
    }

    function deploy() public virtual {}
}
