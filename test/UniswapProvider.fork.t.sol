// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {UniswapProvider} from "../src/providers/UniswapProvider.sol";
import {mainnet} from "../script/addresses.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SellAmountMismatch} from "../src/interfaces/Errors.sol";
import {console} from "lib/forge-std/src/console.sol";
import {
    PoolKey,
    IPoolManager,
    PoolStateLibrary,
    BaseData,
    SwapFlags,
    PoolId,
    PoolIdLibrary
} from "../src/libs/Uniswap.sol";

contract TestUniswapProviderFork is Test {
    using SafeERC20 for IERC20;
    using Address for address;
    using PoolStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    UniswapProvider public uniswapProvider;
    IPoolManager public poolManager;

    function setUp() public {
        vm.createSelectFork("mainnet");
        uniswapProvider = new UniswapProvider(mainnet.UNISWAP_V4_ROUTER, mainnet.POOL_MANAGER);
        uniswapProvider.initialize(address(this));
        vm.deal(address(uniswapProvider), 0);
        poolManager = IPoolManager(mainnet.POOL_MANAGER);
    }

    function _getPoolPrice(PoolKey memory key) internal view returns (uint256) {
        PoolId poolId = PoolIdLibrary.toId(key);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        // price = (sqrtPriceX96 / 2^96)^2 = (sqrtPriceX96^2) / (2^192)
        // Use mulDiv to avoid overflow and maintain precision
        // Calculate price with 18 decimals precision: price = (sqrtPriceX96^2 * 1e18) / (2^192)
        // Use nested mulDiv to avoid overflow: first multiply sqrtPriceX96 * 1e18, then multiply by sqrtPriceX96, then divide by Q192
        uint256 q192 = 2 ** 192;
        return Math.mulDiv(Math.mulDiv(uint256(sqrtPriceX96), 1e18, 1), uint256(sqrtPriceX96), q192);
    }

    function test_SwapETHToUSDT() public {
        PoolKey memory poolKey = PoolKey({
            currency0: address(0), currency1: address(mainnet.USDT), fee: 3000, tickSpacing: 60, hooks: address(0)
        });

        uint256 price = _getPoolPrice(poolKey);
        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = Math.mulDiv(price, 95, 100);

        BaseData memory baseData = BaseData({
            amount: sellAmount,
            amountLimit: buyAmountMin,
            payer: address(uniswapProvider), // UniswapProvider will send ETH to Router
            receiver: address(this), // Test contract receives USDT
            flags: SwapFlags.SINGLE_SWAP
        });

        bytes memory swapData = abi.encode(baseData, true, poolKey, "");

        uint256 usdtBalanceBefore = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        vm.deal(address(this), 1 ether);

        uniswapProvider.swap{value: sellAmount}(swapData);

        uint256 usdtBalanceAfter = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        assertGt(usdtBalanceAfter, usdtBalanceBefore);
        assertGe(usdtBalanceAfter - usdtBalanceBefore, buyAmountMin);
    }

    function test_SwapUSDCToETH() public {
        PoolKey memory poolKey = PoolKey({
            currency0: address(0), currency1: address(mainnet.USDC), fee: 3000, tickSpacing: 60, hooks: address(0)
        });

        uint256 price = _getPoolPrice(poolKey);
        uint256 sellAmount = 1000 * 1e6;
        uint256 expectedEthOutput = Math.mulDiv(sellAmount, 1e18, price);
        uint256 buyAmountMin = Math.mulDiv(expectedEthOutput, 95, 100);

        BaseData memory baseData = BaseData({
            amount: sellAmount,
            amountLimit: buyAmountMin,
            payer: address(uniswapProvider),
            receiver: address(uniswapProvider),
            flags: SwapFlags.SINGLE_SWAP
        });

        bytes memory swapData = abi.encode(baseData, false, poolKey, "");

        uint256 ethBalanceBefore = address(this).balance;
        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(uniswapProvider), sellAmount);
        uniswapProvider.swap(swapData);
        uint256 ethBalanceAfter = address(this).balance;
        assertGt(ethBalanceAfter, ethBalanceBefore);
        assertGe(ethBalanceAfter - ethBalanceBefore, buyAmountMin);
    }

    function _skip_test_SwapUsdtToETH() public {
        PoolKey memory poolKey = PoolKey({
            currency0: address(0), currency1: address(mainnet.USDT), fee: 3000, tickSpacing: 60, hooks: address(0)
        });

        uint256 price = _getPoolPrice(poolKey);
        uint256 sellAmount = 1000 * 1e6;
        uint256 expectedEthOutput = Math.mulDiv(sellAmount, 1e18, price);
        uint256 buyAmountMin = Math.mulDiv(expectedEthOutput, 95, 100);

        BaseData memory baseData = BaseData({
            amount: sellAmount,
            amountLimit: buyAmountMin,
            payer: address(uniswapProvider),
            receiver: address(uniswapProvider),
            flags: SwapFlags.SINGLE_SWAP
        });

        bytes memory swapData = abi.encode(baseData, false, poolKey, "");

        uint256 ethBalanceBefore = address(this).balance;
        deal(address(mainnet.USDT), address(this), sellAmount);
        IERC20(address(mainnet.USDT)).safeApprove(address(uniswapProvider), sellAmount);
        uniswapProvider.swap(swapData);
        uint256 ethBalanceAfter = address(this).balance;
        assertGt(ethBalanceAfter, ethBalanceBefore);
        assertGe(ethBalanceAfter - ethBalanceBefore, buyAmountMin);
    }

    receive() external payable {}
}

