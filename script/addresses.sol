// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IAaveV3} from "../src/libs/Aave.sol";
import {IUniswapV4Router04} from "../src/libs/Uniswap.sol";

library mainnet {
    IAaveV3 public constant AAVE_V3 = IAaveV3(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e);
    IUniswapV4Router04 public constant UNISWAP_V4_ROUTER =
        IUniswapV4Router04(0x00000000000044a361Ae3cAc094c9D1b14Eece97);
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
}

library sepolia {
    IAaveV3 public constant AAVE_V3 = IAaveV3(0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A);
    IUniswapV4Router04 public constant UNISWAP_V4_ROUTER =
        IUniswapV4Router04(0x00000000000044a361Ae3cAc094c9D1b14Eece97);
    address public constant WBTC = 0x29f2D40B0605204364af54EC677bD022dA425d03;
    address public constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address public constant USDT = 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06;
    address public constant USDC = 0x00000000100aaAF8Cff772A414b18168FA758af9;
}
