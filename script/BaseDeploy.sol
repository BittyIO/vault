// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Script} from "lib/forge-std/src/Script.sol";
import {Config} from "lib/forge-std/src/Config.sol";
import {console2} from "lib/forge-std/src/console2.sol";

abstract contract DeployScript is Script, Config {
    function __toUpper(string memory str) private pure returns (string memory) {
        bytes memory strb = bytes(str);
        bytes memory copy = new bytes(strb.length);
        for (uint256 i = 0; i < strb.length; i++) {
            bytes1 b = strb[i];
            if (b >= 0x61 && b <= 0x7A) {
                copy[i] = bytes1(uint8(b) - 32);
            } else {
                copy[i] = b;
            }
        }
        return string(copy);
    }

    function deploy(string memory chainName) public {
        console2.log("Forking chain", chainName);
        vm.createSelectFork(chainName);
        string memory configPath = string.concat("./deployments/", chainName, ".toml");
        _loadConfig(configPath, true);
        vm.startBroadcast(vm.envUint(string.concat(__toUpper(chainName), "_PRIVATE_KEY")));
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
