// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {UniswapV4Provider} from "../src/providers/UniswapV4Provider.sol";
import {UniswapV3Provider} from "../src/providers/UniswapV3Provider.sol";
import {mainnet} from "../script/addresses.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SellAmountMismatch} from "../src/interfaces/Errors.sol";
import {console} from "lib/forge-std/src/console.sol";
import {
    PoolKey as V4PoolKey,
    PathKey,
    IPoolManager,
    PoolStateLibrary,
    BaseData,
    SwapFlags,
    PoolId,
    PoolIdLibrary
} from "../src/libs/uniswap/v4/Uniswap.sol";
import {
    Path,
    IUniswapV3Factory,
    IUniswapV3Pool,
    PoolAddress,
    PoolKey as V3PoolKey,
    IUniswapV3Router
} from "../src/libs/uniswap/v3/Uniswap.sol";

contract TestUniswapProviderFork is Test {
    using SafeERC20 for IERC20;
    using Address for address;
    using PoolStateLibrary for IPoolManager;
    using PoolIdLibrary for V4PoolKey;
    using Path for bytes;

    UniswapV4Provider public v4Provider;
    UniswapV3Provider public v3Provider;
    IPoolManager public poolManager;

    function setUp() public {
        vm.createSelectFork("mainnet");
        v4Provider = new UniswapV4Provider(mainnet.UNISWAP_V4_ROUTER, mainnet.POOL_MANAGER);
        v4Provider.initialize(address(this));
        vm.deal(address(v4Provider), 0);
        poolManager = IPoolManager(mainnet.POOL_MANAGER);

        v3Provider = new UniswapV3Provider(mainnet.UNISWAP_V3_ROUTER);
        v3Provider.initialize(address(this));
        vm.deal(address(v3Provider), 0);
    }

    function _getV4PoolPrice(V4PoolKey memory key) internal view returns (uint256) {
        PoolId poolId = PoolIdLibrary.toId(key);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        // price = (sqrtPriceX96 / 2^96)^2 = (sqrtPriceX96^2) / (2^192)
        // Use mulDiv to avoid overflow and maintain precision
        // Calculate price with 18 decimals precision: price = (sqrtPriceX96^2 * 1e18) / (2^192)
        // Use nested mulDiv to avoid overflow: first multiply sqrtPriceX96 * 1e18, then multiply by sqrtPriceX96, then divide by Q192
        uint256 q192 = 2 ** 192;
        return Math.mulDiv(Math.mulDiv(uint256(sqrtPriceX96), 1e18, 1), uint256(sqrtPriceX96), q192);
    }

    function _getV3PoolPrice(address tokenIn, address tokenOut, uint24 fee) internal view returns (uint256) {
        // Ensure token0 < token1 for Uniswap V3
        address token0 = tokenIn < tokenOut ? tokenIn : tokenOut;
        address token1 = tokenIn < tokenOut ? tokenOut : tokenIn;

        address pool =
            IUniswapV3Factory(IUniswapV3Router(mainnet.UNISWAP_V3_ROUTER).factory()).getPool(token0, token1, fee);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        // sqrtPriceX96 = sqrt(token1/token0) * 2^96
        // price = (sqrtPriceX96 / 2^96)^2 = token1/token0
        uint256 q192 = 2 ** 192;
        uint256 priceToken1PerToken0 =
            Math.mulDiv(Math.mulDiv(uint256(sqrtPriceX96), 1e18, 1), uint256(sqrtPriceX96), q192);

        // Return price of tokenOut per tokenIn
        // If tokenIn is token0, price = token1/token0 = tokenOut/tokenIn
        // If tokenIn is token1, price = token0/token1 = 1 / (token1/token0) = tokenOut/tokenIn
        if (tokenIn == token0) {
            return priceToken1PerToken0;
        } else {
            // Invert: price = 1 / priceToken1PerToken0
            return Math.mulDiv(q192, 1e18, Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1));
        }
    }

    function test_V4_SwapETHToUSDT() public {
        PathKey memory pathKey = PathKey({
            intermediateCurrency: address(mainnet.USDT), fee: 3000, tickSpacing: 60, hooks: address(0), hookData: ""
        });

        (V4PoolKey memory poolKey,) = pathKey.getPoolAndSwapDirection(address(0));

        uint256 price = _getV4PoolPrice(poolKey);
        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = Math.mulDiv(price, 95, 100);

        BaseData memory baseData = BaseData({
            amount: sellAmount, amountLimit: buyAmountMin, payer: address(0), receiver: address(0), flags: 0
        });

        PathKey[] memory paths = new PathKey[](1);
        paths[0] = pathKey;
        bytes memory swapData = abi.encode(baseData, address(0), paths);

        uint256 usdtBalanceBefore = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        vm.deal(address(this), 1 ether);

        v4Provider.swap{value: sellAmount}(swapData);

        uint256 usdtBalanceAfter = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        assertGt(usdtBalanceAfter, usdtBalanceBefore);
        assertGe(usdtBalanceAfter - usdtBalanceBefore, buyAmountMin);
    }

    function test_V4_SwapUSDCToETH() public {
        PathKey memory pathKey =
            PathKey({intermediateCurrency: address(0), fee: 3000, tickSpacing: 60, hooks: address(0), hookData: ""});

        (V4PoolKey memory poolKey,) = pathKey.getPoolAndSwapDirection(address(mainnet.USDC));

        uint256 price = _getV4PoolPrice(poolKey);
        uint256 sellAmount = 1000 * 1e6;
        uint256 expectedEthOutput = Math.mulDiv(sellAmount, 1e18, price);
        uint256 buyAmountMin = Math.mulDiv(expectedEthOutput, 95, 100);

        BaseData memory baseData = BaseData({
            amount: sellAmount, amountLimit: buyAmountMin, payer: address(0), receiver: address(0), flags: 0
        });

        PathKey[] memory paths = new PathKey[](1);
        paths[0] = pathKey;
        bytes memory swapData = abi.encode(baseData, address(mainnet.USDC), paths);

        uint256 ethBalanceBefore = address(this).balance;
        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(v4Provider), sellAmount);
        v4Provider.swap(swapData);
        uint256 ethBalanceAfter = address(this).balance;
        assertGt(ethBalanceAfter, ethBalanceBefore);
        assertGe(ethBalanceAfter - ethBalanceBefore, buyAmountMin);
    }

    // ============ Uniswap V3 Provider Tests ============

    function test_V3_SwapWETHToUSDT() public {
        address[] memory path = new address[](2);
        path[0] = address(mainnet.WETH);
        path[1] = address(mainnet.USDT);

        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000; // 0.3% fee

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 price = _getV3PoolPrice(path[0], path[1], fees[0]);
        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = Math.mulDiv(price, 95, 100);

        bytes memory swapData = abi.encode(encodedPath, address(0), sellAmount, buyAmountMin);

        uint256 usdtBalanceBefore = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        deal(address(mainnet.WETH), address(this), sellAmount);
        IERC20(address(mainnet.WETH)).safeApprove(address(v3Provider), sellAmount);

        v3Provider.swap(swapData);

        uint256 usdtBalanceAfter = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        assertGt(usdtBalanceAfter, usdtBalanceBefore);
        assertGe(usdtBalanceAfter - usdtBalanceBefore, buyAmountMin);
    }

    function test_V3_SwapUSDCToETH() public {
        address[] memory path = new address[](2);
        path[0] = address(mainnet.USDC);
        path[1] = address(mainnet.WETH); // WETH

        uint24[] memory fees = new uint24[](1);
        fees[0] = 500; // 0.05% fee

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 price = _getV3PoolPrice(address(mainnet.USDC), address(mainnet.WETH), 3000);
        uint256 sellAmount = 1000 * 1e6;
        uint256 expectedEthOutput = Math.mulDiv(sellAmount, 1e18, price);
        uint256 buyAmountMin = Math.mulDiv(expectedEthOutput, 95, 100);

        bytes memory swapData = abi.encode(encodedPath, address(0), sellAmount, buyAmountMin);

        uint256 wethBalanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(v3Provider), sellAmount);

        v3Provider.swap(swapData);

        uint256 wethBalanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertGt(wethBalanceAfter, wethBalanceBefore);
        assertGe(wethBalanceAfter - wethBalanceBefore, buyAmountMin);
    }

    function test_V3_SwapUSDTToWETH() public {
        address[] memory path = new address[](2);
        path[0] = address(mainnet.USDT);
        path[1] = address(mainnet.WETH); // ETH

        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000; // 0.3% fee

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 price = _getV3PoolPrice(address(mainnet.USDT), address(mainnet.WETH), 3000);
        uint256 sellAmount = 1000 * 1e6;
        uint256 expectedEthOutput = Math.mulDiv(sellAmount, 1e18, price);
        uint256 buyAmountMin = Math.mulDiv(expectedEthOutput, 95, 100);

        bytes memory swapData = abi.encode(encodedPath, address(0), sellAmount, buyAmountMin);

        uint256 wethBalanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        deal(address(mainnet.USDT), address(this), sellAmount);
        IERC20(address(mainnet.USDT)).safeApprove(address(v3Provider), sellAmount);

        v3Provider.swap(swapData);

        uint256 wethBalanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertGt(wethBalanceAfter, wethBalanceBefore);
        assertGe(wethBalanceAfter - wethBalanceBefore, buyAmountMin);
    }

    receive() external payable {}
}

