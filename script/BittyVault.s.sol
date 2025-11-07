// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";

contract CounterScript is Script {
    BittyVault public bittyVault;

    // WETH addresses by chain
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant SEPOLIA_WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        bittyVault = new BittyVault();

        address wethAddress = getWETHAddress();
        bittyVault.setAsset(IAssetManager.AssetType.WETH, wethAddress);

        vm.stopBroadcast();
    }

    function getWETHAddress() internal view returns (address) {
        uint256 chainId = block.chainid;

        if (chainId == 1) {
            // Ethereum Mainnet
            return MAINNET_WETH;
        } else if (chainId == 11155111) {
            // Sepolia Testnet
            return SEPOLIA_WETH;
        } else {
            // Default to Mainnet address for other chains
            // This can be overridden via environment variable
            address envWeth = vm.envOr("WETH_ADDRESS", address(0));
            if (envWeth != address(0)) {
                return envWeth;
            }
            return MAINNET_WETH;
        }
    }
}
