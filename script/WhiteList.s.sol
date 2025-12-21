// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {WhiteList} from "../src/WhiteList.sol";
import {console2} from "lib/forge-std/src/console2.sol";
import {DeployScript} from "./BaseDeploy.sol";

contract WhiteListScript is DeployScript {
    WhiteList public whiteList;

    function deploy() public override {
        address[] memory assetAddresses = new address[](2);
        assetAddresses[0] = getAddress("WBTC");
        assetAddresses[1] = getAddress("WETH");
        address[] memory stableCoinAddresses = new address[](2);
        stableCoinAddresses[0] = getAddress("USDT");
        stableCoinAddresses[1] = getAddress("USDC");
        address[] memory yieldProviders = new address[](2);
        yieldProviders[0] = getAddress("AAVE_PROVIDER");
        yieldProviders[1] = getAddress("LIDO_PROVIDER");
        address[] memory swapProviders = new address[](2);
        swapProviders[0] = getAddress("UNISWAP_V4_PROVIDER");
        swapProviders[1] = getAddress("UNISWAP_V3_PROVIDER");

        whiteList = new WhiteList();
        console2.log("WhiteList deployed at", address(whiteList));
        whiteList.addAssets(assetAddresses);
        whiteList.addStableCoins(stableCoinAddresses);
        whiteList.addYieldProviders(yieldProviders);
        whiteList.addSwapProviders(swapProviders);

        saveAddress("WHITE_LIST", address(whiteList));
    }
}
