// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {AaveV3Provider} from "../src/providers/AaveV3Provider.sol";
import {UniswapV3Provider} from "../src/providers/UniswapV3Provider.sol";
import {CoWSwapProvider} from "../src/providers/CoWSwapProvider.sol";
import {UniswapXProvider} from "../src/providers/UniswapXProvider.sol";
import {LidoV2Provider} from "../src/providers/LidoV2Provider.sol";

contract ProvidersScript is DeployScript {
    function deploy() public override {
        address aaveV3 = getAddress("AAVE_V3");
        address poolDataProvider = getAddress("POOL_DATA_PROVIDER");
        address steth = getAddress("STETH");
        address unsteth = getAddress("UNSTETH");
        address weth = getAddress("WETH");
        address uniswapV3Router = getAddress("UNISWAP_V3_ROUTER");
        address cowSettlement = getAddress("COW_SETTLEMENT");
        address cowVaultRelayer = getAddress("COW_VAULT_RELAYER");
        address uniswapXReactor = getAddress("UNISWAPX_REACTOR");
        address permit2 = getAddress("PERMIT2");

        AaveV3Provider aaveProvider = new AaveV3Provider(aaveV3, poolDataProvider);
        console2.log("AaveProvider deployed at", address(aaveProvider));
        LidoV2Provider lidoProvider = new LidoV2Provider(steth, unsteth, weth);
        console2.log("LidoProvider deployed at", address(lidoProvider));
        UniswapV3Provider uniswapV3Provider =
            new UniswapV3Provider(uniswapV3Router, getAddress("UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER"));
        console2.log("UniswapV3Provider deployed at", address(uniswapV3Provider));
        CoWSwapProvider cowSwapProvider = new CoWSwapProvider(cowSettlement, cowVaultRelayer);
        console2.log("CoWSwapProvider deployed at", address(cowSwapProvider));
        UniswapXProvider uniswapXProvider = new UniswapXProvider(uniswapXReactor, permit2);
        console2.log("UniswapXProvider deployed at", address(uniswapXProvider));

        saveAddress("AAVE_PROVIDER", address(aaveProvider));
        saveAddress("LIDO_PROVIDER", address(lidoProvider));
        saveAddress("UNISWAP_V3_PROVIDER", address(uniswapV3Provider));
        saveAddress("COW_SWAP_PROVIDER", address(cowSwapProvider));
        saveAddress("UNISWAPX_PROVIDER", address(uniswapXProvider));
    }
}
