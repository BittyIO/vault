// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {Script} from "lib/forge-std/src/Script.sol";
import {sepolia} from "../addresses.sol";
import {console2} from "lib/forge-std/src/console2.sol";
import {AaveProvider} from "../../src/providers/AaveProvider.sol";
import {UniswapV4Provider} from "../../src/providers/UniswapV4Provider.sol";
import {LidoProvider} from "../../src/providers/LidoProvider.sol";

contract ProvidersScript is Script {
    function setUp() public {}

    function run() public {
        vm.createSelectFork("sepolia");
        vm.startBroadcast(vm.envUint("SEPOLIA_PRIVATE_KEY"));
        console2.log("Deploying migrator...");
        AaveProvider aaveProvider = new AaveProvider(sepolia.AAVE_V3, sepolia.POOL_DATA_PROVIDER);
        console2.log("AaveProvider deployed at", address(aaveProvider));
        UniswapV4Provider uniswapV4Provider = new UniswapV4Provider(sepolia.UNISWAP_V4_ROUTER, sepolia.POOL_MANAGER);
        console2.log("UniswapV4Provider deployed at", address(uniswapV4Provider));
        LidoProvider lidoProvider = new LidoProvider(sepolia.STETH, sepolia.UNSTETH, sepolia.WETH);
        console2.log("LidoProvider deployed at", address(lidoProvider));
        vm.stopBroadcast();
    }
}
