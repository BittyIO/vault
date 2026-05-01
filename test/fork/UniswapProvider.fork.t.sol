// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UniswapV3Provider} from "provider-contracts/src/providers/UniswapV3Provider.sol";
import {mainnet} from "provider-contracts/script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {
    PoolKey as V4PoolKey,
    PathKey,
    IPoolManager,
    PoolStateLibrary,
    PoolId,
    PoolIdLibrary
} from "provider-contracts/src/libs/uniswap/v4/Uniswap.sol";
import {Path, IUniswapV3Factory, IUniswapV3Pool, IUniswapV3Router} from "provider-contracts/src/libs/uniswap/v3/Uniswap.sol";
import {INonfungiblePositionManager} from "provider-contracts/src/libs/uniswap/v3/Uniswap.sol";

contract TestUniswapProviderFork is Test {
    using SafeERC20 for IERC20;
    using Address for address;
    using PoolStateLibrary for IPoolManager;
    using PoolIdLibrary for V4PoolKey;
    using Path for bytes;

    UniswapV3Provider public v3Provider;
    IPoolManager public poolManager;

    function setUp() public {
        vm.createSelectFork("mainnet");
        poolManager = IPoolManager(mainnet.POOL_MANAGER);

        v3Provider = new UniswapV3Provider(mainnet.UNISWAP_V3_ROUTER, mainnet.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER);
        v3Provider.initialize(address(this));
        vm.deal(address(v3Provider), 0);
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

        bytes memory swapData = abi.encode(path[0], sellAmount, path[1], buyAmountMin, encodedPath);

        uint256 usdtBalanceBefore = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        deal(address(mainnet.WETH), address(this), sellAmount);
        IERC20(address(mainnet.WETH)).safeApprove(address(v3Provider), sellAmount);

        v3Provider.swap(swapData);

        uint256 usdtBalanceAfter = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        assertGt(usdtBalanceAfter, usdtBalanceBefore);
        assertGe(usdtBalanceAfter - usdtBalanceBefore, buyAmountMin);
    }

    function test_V3_SwapUSDCToWETH() public {
        address[] memory path = new address[](2);
        path[0] = address(mainnet.USDC);
        path[1] = address(mainnet.WETH);

        uint24[] memory fees = new uint24[](1);
        fees[0] = 500; // 0.05% fee

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 price = _getV3PoolPrice(address(mainnet.USDC), address(mainnet.WETH), 3000);
        uint256 sellAmount = 1000 * 1e6;
        uint256 expectedEthOutput = Math.mulDiv(sellAmount, 1e18, price);
        uint256 buyAmountMin = Math.mulDiv(expectedEthOutput, 95, 100);

        bytes memory swapData = abi.encode(path[0], sellAmount, path[1], buyAmountMin, encodedPath);

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
        path[1] = address(mainnet.WETH);

        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000; // 0.3% fee

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 price = _getV3PoolPrice(address(mainnet.USDT), address(mainnet.WETH), 3000);
        uint256 sellAmount = 1000 * 1e6;
        uint256 expectedEthOutput = Math.mulDiv(sellAmount, 1e18, price);
        uint256 buyAmountMin = Math.mulDiv(expectedEthOutput, 95, 100);

        bytes memory swapData = abi.encode(path[0], sellAmount, path[1], buyAmountMin, encodedPath);

        uint256 wethBalanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        deal(address(mainnet.USDT), address(this), sellAmount);
        IERC20(address(mainnet.USDT)).safeApprove(address(v3Provider), sellAmount);

        v3Provider.swap(swapData);

        uint256 wethBalanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertGt(wethBalanceAfter, wethBalanceBefore);
        assertGe(wethBalanceAfter - wethBalanceBefore, buyAmountMin);
    }

    function test_V3_SwapUSDCToWETHToUSDT() public {
        address[] memory path = new address[](3);
        path[0] = address(mainnet.USDC);
        path[1] = address(mainnet.WETH);
        path[2] = address(mainnet.USDT);

        uint24[] memory fees = new uint24[](2);
        fees[0] = 500; // 0.05% fee for USDC -> WETH
        fees[1] = 3000; // 0.3% fee for WETH -> USDT

        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 sellAmount = 1000 * 1e6;

        uint256 price1 = _getV3PoolPrice(address(mainnet.USDC), address(mainnet.WETH), 500);
        uint256 expectedWethOutput = Math.mulDiv(sellAmount, 1e18, price1);

        uint256 price2 = _getV3PoolPrice(address(mainnet.WETH), address(mainnet.USDT), 3000);
        uint256 expectedUsdtOutput = Math.mulDiv(expectedWethOutput, price2, 1e18);

        uint256 buyAmountMin = Math.mulDiv(expectedUsdtOutput, 95, 100);

        bytes memory swapData = abi.encode(path[0], sellAmount, path[2], buyAmountMin, encodedPath);

        uint256 usdtBalanceBefore = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(v3Provider), sellAmount);

        v3Provider.swap(swapData);

        uint256 usdtBalanceAfter = IERC20(address(mainnet.USDT)).balanceOf(address(this));
        assertGt(usdtBalanceAfter, usdtBalanceBefore);
        assertGe(usdtBalanceAfter - usdtBalanceBefore, buyAmountMin);
    }

    // ============ Uniswap V3 AMM (addLiquidity / removeLiquidity / claimAMMFees / getLiquidity) ============

    bytes32 constant ERC721_TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    function _mintV3PositionAndGetTokenId() internal returns (uint256 tokenId) {
        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;
        uint24 fee = 3000;
        int24 tickSpacing = 60;

        address pool =
            IUniswapV3Factory(IUniswapV3Router(mainnet.UNISWAP_V3_ROUTER).factory()).getPool(token0, token1, fee);
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 tickLower = (currentTick / tickSpacing) * tickSpacing - tickSpacing * 10;
        int24 tickUpper = (currentTick / tickSpacing) * tickSpacing + tickSpacing * 10;

        uint256 amount0Desired = token0 == mainnet.WETH ? 0.01 ether : 20 * 1e6;
        uint256 amount1Desired = token1 == mainnet.WETH ? 0.01 ether : 20 * 1e6;

        deal(token0, address(this), amount0Desired);
        deal(token1, address(this), amount1Desired);
        IERC20(token0).safeApprove(address(v3Provider), amount0Desired);
        IERC20(token1).safeApprove(address(v3Provider), amount1Desired);

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(0),
            deadline: block.timestamp
        });
        bytes memory addData = abi.encode(true, abi.encode(mintParams));

        vm.recordLogs();
        v3Provider.addLiquidity(addData);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        address npm = mainnet.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER;
        bytes32 toTopic = bytes32(uint256(uint160(address(v3Provider))));
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == npm && entries[i].topics[0] == ERC721_TRANSFER_TOPIC
                    && entries[i].topics[1] == bytes32(uint256(0)) && entries[i].topics[2] == toTopic
                    && entries[i].topics.length > 3
            ) {
                tokenId = uint256(entries[i].topics[3]);
                break;
            }
        }
        require(tokenId > 0, "tokenId from mint");
        return tokenId;
    }

    function test_V3_AddLiquidity_Mint() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();
        assertGt(tokenId, 0, "tokenId from mint");

        uint256 liquidity = v3Provider.getLiquidity(abi.encode(tokenId));
        assertGt(liquidity, 0, "liquidity after mint");
    }

    function test_V3_GetLiquidity_ClaimFees() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        uint256 liquidity = v3Provider.getLiquidity(abi.encode(tokenId));
        assertGt(liquidity, 0, "liquidity after mint");

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        v3Provider.claimAMMFees(abi.encode(collectParams));
    }

    /// @notice `CollectParams.recipient` in calldata must be ignored; fees go to the provider owner only.
    function test_V3_ClaimFees_EncodedRecipientDoesNotReceiveTokens() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();
        assertGt(v3Provider.getLiquidity(abi.encode(tokenId)), 0, "liquidity after mint");

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;
        address encodedRecipient = makeAddr("encodedRecipient");

        uint256 bal0Before = IERC20(token0).balanceOf(encodedRecipient);
        uint256 bal1Before = IERC20(token1).balanceOf(encodedRecipient);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: encodedRecipient, amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        v3Provider.claimAMMFees(abi.encode(collectParams));

        assertEq(IERC20(token0).balanceOf(encodedRecipient), bal0Before, "token0 must not go to encoded recipient");
        assertEq(IERC20(token1).balanceOf(encodedRecipient), bal1Before, "token1 must not go to encoded recipient");
    }

    function test_V3_RemoveLiquidity() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        uint256 liquidityAfterMint = v3Provider.getLiquidity(abi.encode(tokenId));
        assertGt(liquidityAfterMint, 0, "liquidity after mint");

        uint128 liquidityToDecrease =
            liquidityAfterMint >= 2 ? uint128(liquidityAfterMint / 2) : uint128(liquidityAfterMint);
        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToDecrease,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });
        v3Provider.removeLiquidity(abi.encode(decreaseParams));

        uint256 liquidityAfterDecrease = v3Provider.getLiquidity(abi.encode(tokenId));
        assertEq(liquidityAfterDecrease, liquidityAfterMint - liquidityToDecrease, "liquidity after decrease");

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        v3Provider.claimAMMFees(abi.encode(collectParams));

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        assertTrue(balance0 > 0 || balance1 > 0, "should receive tokens from decrease and collect");
    }

    function test_V3_RemoveLiquidity_CollectsTokensDirectly() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;

        uint128 liquidity = uint128(v3Provider.getLiquidity(abi.encode(tokenId)));
        assertGt(liquidity, 0, "liquidity before remove");

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            });

        v3Provider.removeLiquidity(abi.encode(decreaseParams));

        uint256 balance0After = IERC20(token0).balanceOf(address(this));
        uint256 balance1After = IERC20(token1).balanceOf(address(this));

        assertTrue(
            balance0After > balance0Before || balance1After > balance1Before, "tokens must arrive without claimAMMFees"
        );
        assertEq(IERC20(token0).balanceOf(address(v3Provider)), 0, "provider must hold no token0");
        assertEq(IERC20(token1).balanceOf(address(v3Provider)), 0, "provider must hold no token1");
        assertEq(v3Provider.getLiquidity(abi.encode(tokenId)), 0, "liquidity must be zero after full removal");
    }

    function test_V3_AddLiquidity_Mint_ReturnsUnusedTokens() public {
        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;
        uint24 fee = 3000;
        int24 tickSpacing = 60;

        address pool =
            IUniswapV3Factory(IUniswapV3Router(mainnet.UNISWAP_V3_ROUTER).factory()).getPool(token0, token1, fee);
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 tickLower = (currentTick / tickSpacing) * tickSpacing - tickSpacing * 10;
        int24 tickUpper = (currentTick / tickSpacing) * tickSpacing + tickSpacing * 10;

        uint256 amount0Desired = token0 == mainnet.WETH ? 1 ether : 5000 * 1e6;
        uint256 amount1Desired = token1 == mainnet.WETH ? 1 ether : 5000 * 1e6;

        deal(token0, address(this), amount0Desired);
        deal(token1, address(this), amount1Desired);
        IERC20(token0).safeApprove(address(v3Provider), amount0Desired);
        IERC20(token1).safeApprove(address(v3Provider), amount1Desired);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(0),
            deadline: block.timestamp
        });
        v3Provider.addLiquidity(abi.encode(true, abi.encode(mintParams)));

        uint256 balance0After = IERC20(token0).balanceOf(address(this));
        uint256 balance1After = IERC20(token1).balanceOf(address(this));

        uint256 used0 = balance0Before - balance0After;
        uint256 used1 = balance1Before - balance1After;
        assertLe(used0, amount0Desired, "used0 exceeds desired");
        assertLe(used1, amount1Desired, "used1 exceeds desired");
        assertTrue(used0 < amount0Desired || used1 < amount1Desired, "at least one token should have leftover");
        assertEq(IERC20(token0).balanceOf(address(v3Provider)), 0, "provider clone must hold no token0");
        assertEq(IERC20(token1).balanceOf(address(v3Provider)), 0, "provider clone must hold no token1");
    }

    function test_V3_AddLiquidity_IncreaseLiquidity_ReturnsUnusedTokens() public {
        uint256 tokenId = _mintV3PositionAndGetTokenId();

        address token0 = mainnet.WETH < mainnet.USDC ? mainnet.WETH : mainnet.USDC;
        address token1 = mainnet.WETH < mainnet.USDC ? mainnet.USDC : mainnet.WETH;

        uint256 amount0Desired = token0 == mainnet.WETH ? 1 ether : 5000 * 1e6;
        uint256 amount1Desired = token1 == mainnet.WETH ? 1 ether : 5000 * 1e6;

        deal(token0, address(this), amount0Desired);
        deal(token1, address(this), amount1Desired);
        IERC20(token0).safeApprove(address(v3Provider), amount0Desired);
        IERC20(token1).safeApprove(address(v3Provider), amount1Desired);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseParams =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });
        v3Provider.addLiquidity(abi.encode(false, abi.encode(increaseParams)));

        uint256 balance0After = IERC20(token0).balanceOf(address(this));
        uint256 balance1After = IERC20(token1).balanceOf(address(this));

        uint256 used0 = balance0Before - balance0After;
        uint256 used1 = balance1Before - balance1After;
        assertLe(used0, amount0Desired, "used0 exceeds desired");
        assertLe(used1, amount1Desired, "used1 exceeds desired");
        assertTrue(used0 < amount0Desired || used1 < amount1Desired, "at least one token should have leftover");
        assertEq(IERC20(token0).balanceOf(address(v3Provider)), 0, "provider clone must hold no token0");
        assertEq(IERC20(token1).balanceOf(address(v3Provider)), 0, "provider clone must hold no token1");
    }

    receive() external payable {}
}

