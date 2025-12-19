// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {Migrator} from "../src/Migrator.sol";
import {console2} from "lib/forge-std/src/console2.sol";
import {DeployScript} from "./BaseDeploy.sol";

contract MigratorScript is DeployScript {
    Migrator public migrator;

    function deploy() public override {
        migrator = new Migrator();
        console2.log("Migrator deployed at", address(migrator));
        saveAddress("MIGRATOR", address(migrator));
    }
}
