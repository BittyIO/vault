// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {Script} from "lib/forge-std/src/Script.sol";
import {Migrator} from "../../src/Migrator.sol";
import {console2} from "lib/forge-std/src/console2.sol";

contract MigratorScript is Script {
    Migrator public migrator;

    function setUp() public {}

    function run() public {
        vm.createSelectFork("sepolia");
        vm.startBroadcast(vm.envUint("SEPOLIA_PRIVATE_KEY"));
        console2.log("Deploying migrator...");
        migrator = new Migrator();
        console2.log("Migrator deployed at", address(migrator));
        vm.stopBroadcast();
    }
}
