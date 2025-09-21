// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {BittyTrust} from "../src/BittyTrust.sol";

contract CounterScript is Script {
    BittyTrust public bittyTrust;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        bittyTrust = new BittyTrust();

        vm.stopBroadcast();
    }
}
