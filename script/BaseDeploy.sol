// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {Variable, TypeKind} from "forge-std/LibVariable.sol";
import {console2} from "forge-std/console2.sol";

abstract contract DeployScript is Script, Config {
    string[] private _savedKeys;
    address[] private _savedValues;

    function deploy(string memory chainName) public {
        console2.log("Deploying to chain", chainName);
        string memory configPath = string.concat("./deployments/", chainName, ".toml");
        _loadConfig(configPath, true);
        vm.startBroadcast();
        deploy();
        vm.stopBroadcast();
        _flushSavedAddresses();
    }

    function run() public {
        deploy(vm.getChain(block.chainid).name);
    }

    function getAddress(string memory key) public view returns (address) {
        address value = config.get(key).toAddress();
        require(value != address(0), string.concat("Address for key ", key, " not found"));
        return value;
    }

    /**
     * @dev {getAddress} reverts on a missing key. This is for addresses a deployment may legitimately
     *      not have yet, such as an optional relayer.
     */
    function getAddressOr(string memory key, address fallbackValue) public view returns (address) {
        Variable memory v = config.get(key);
        if (v.ty.kind != TypeKind.Address) return fallbackValue;
        address value = v.toAddress();
        return value == address(0) ? fallbackValue : value;
    }

    /**
     * @dev Buffered rather than written straight through, because {Config-set} is an external call to
     *      StdConfig - a helper forge-std deploys INSIDE the simulation. Inside the broadcast window
     *      forge records every such call as a transaction; buffering to this contract's own storage is
     *      an internal write, flushed after the broadcast closes.
     */
    function saveAddress(string memory key, address value) public {
        require(value != address(0), string.concat("Address for key ", key, " is 0x0"));
        _savedKeys.push(key);
        _savedValues.push(value);
    }

    /// @dev Runs after {vm-stopBroadcast}, so these calls are plain simulation and emit no transaction.
    function _flushSavedAddresses() private {
        for (uint256 i = 0; i < _savedKeys.length; i++) {
            config.set(_savedKeys[i], _savedValues[i]);
        }
        delete _savedKeys;
        delete _savedValues;
    }

    function deploy() public virtual {}
}
