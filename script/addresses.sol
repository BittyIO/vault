// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

library mainnet {
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public constant AAVE_V3 = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    address public constant UNISWAP_V4_ROUTER = 0x00000000000044a361Ae3cAc094c9D1b14Eece97;
    address public constant POOL_DATA_PROVIDER = 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant UNSTETH = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    // TODO: should deploy white list contract first, then set the address here
    address public constant WHITE_LIST = 0x0000000000000000000000000000000000000000;
    address public constant MIGRATOR = 0x0000000000000000000000000000000000000000;
}

library sepolia {
    address public constant WBTC = 0x29f2D40B0605204364af54EC677bD022dA425d03;
    address public constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address public constant USDT = 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06;
    address public constant USDC = 0x00000000100aaAF8Cff772A414b18168FA758af9;

    address public constant AAVE_V3 = 0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A;

    address public constant UNISWAP_V4_ROUTER = 0x00000000000044a361Ae3cAc094c9D1b14Eece97;
    address public constant POOL_DATA_PROVIDER = 0x3e9708d80f7B3e43118013075F7e95CE3AB31F31;
    address public constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    address public constant STETH = 0x3e3FE7dBc6B4C189E7128855dD526361c49b40Af;
    address public constant UNSTETH = 0x1583C7b3f4C3B008720E6BcE5726336b0aB25fdd;

    address public constant WHITE_LIST = 0xc2Aef560BEaE08cB4CC3A6D30A15ED1716dC131f;
    address public constant MIGRATOR = 0x0000000000000000000000000000000000000000;
}
