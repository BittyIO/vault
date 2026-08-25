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
     *
     *      Inspects the variable's type rather than catching a revert from `this.getAddress(...)`:
     *      that would be an external self-call, and forge rejects `address(this)` in scripts because
     *      a script contract is ephemeral and its address means nothing.
     */
    function getAddressOr(string memory key, address fallbackValue) public view returns (address) {
        Variable memory v = config.get(key);
        if (v.ty.kind != TypeKind.Address) return fallbackValue;
        address value = v.toAddress();
        return value == address(0) ? fallbackValue : value;
    }

    /**
     * @dev Buffered rather than written straight through, because {Config-set} is an external call to
     *      StdConfig - a helper forge-std deploys INSIDE the simulation to hold the parsed TOML, at an
     *      address that exists nowhere on the target chain.
     *
     *      Inside the broadcast window forge records every such call as a transaction to be sent, so a
     *      real broadcast would emit one pointless ~21k-gas send per key, to an address with no code,
     *      each preceded by "Script contains a transaction to 0x... which does not contain any code".
     *      They do nothing on-chain and they bury the real deployment transactions in the run log.
     *
     *      Pushing to this contract's own storage is an internal write, so nothing is recorded; the
     *      buffer is flushed once the broadcast has closed and writes exactly the same TOML.
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
