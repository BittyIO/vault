// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "lib/forge-std/src/Script.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {mainnet, sepolia} from "../script/addresses.sol";
import {console2} from "lib/forge-std/src/console2.sol";

contract WhiteListScript is Script {
    WhiteList public whiteList;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        whiteList = new WhiteList();
        address[] memory assetAddresses = new address[](2);
        assetAddresses[0] = getWBTCAddress();
        assetAddresses[1] = getWETHAddress();
        address[] memory stableCoinAddresses = new address[](2);
        stableCoinAddresses[0] = getUSDTAddress();
        stableCoinAddresses[1] = getUSDCAddress();
        address[] memory yieldProviders = new address[](1);
        yieldProviders[0] = getAAVEV3Address();
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = getUniswapV4RouterAddress();
        whiteList.addAssets(assetAddresses);
        whiteList.addStableCoins(stableCoinAddresses);
        whiteList.addYieldProviders(yieldProviders);
        whiteList.addSwapProviders(swapProviders);

        vm.stopBroadcast();
        console2.log(address(whiteList));
    }

    function getWETHAddress() internal view returns (address) {
        uint256 chainId = block.chainid;

        if (chainId == 1) {
            return mainnet.WETH;
        } else if (chainId == 11155111) {
            return sepolia.WETH;
        }
        return address(0);
    }

    function getWBTCAddress() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return mainnet.WBTC;
        } else if (chainId == 11155111) {
            return sepolia.WBTC;
        }
        return address(0);
    }

    function getUSDTAddress() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return mainnet.USDT;
        } else if (chainId == 11155111) {
            return sepolia.USDT;
        }
        return address(0);
    }

    function getUSDCAddress() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return mainnet.USDC;
        } else if (chainId == 11155111) {
            return sepolia.USDC;
        }
        return address(0);
    }

    function getAAVEV3Address() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return mainnet.AAVE_V3;
        } else if (chainId == 11155111) {
            return sepolia.AAVE_V3;
        }
        return address(0);
    }

    function getUniswapV4RouterAddress() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return mainnet.UNISWAP_V4_ROUTER;
        } else if (chainId == 11155111) {
            return sepolia.UNISWAP_V4_ROUTER;
        }
        return address(0);
    }
}
