// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {AssetManager} from "../src/AssetManager.sol";
import {ITrust} from "../src/interfaces/ITrust.sol";
import {PermissionController} from "../src/PermissionController.sol";
import {mainnet} from "../script/addresses.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {console} from "lib/forge-std/src/console.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {
    AssetType,
    InvalidAssetType,
    AssetAlreadySet,
    RebalanceLimit,
    InsufficientBalance,
    AmountIsZero,
    AddressZero
} from "../src/AssetManager.sol";
import {IPoolDataProvider} from "../src/libs/Aave.sol";

import {
    PoolKey,
    IPoolManager,
    PoolStateLibrary,
    BaseData,
    SwapFlags,
    PoolId,
    PoolIdLibrary
} from "../src/libs/Uniswap.sol";

import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract TestAssetManager is Test, AssetManager {
    using SafeERC20 for IERC20;
    using Address for address;
    using PoolStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    IPoolDataProvider public poolDataProvider;
    IPoolManager public poolManager;

    function swap(
        address sellAssetAddress,
        uint256 sellAmount,
        AssetType toAssetType,
        uint256 buyAmountMin,
        bytes memory data
    ) external {
        _swap(sellAssetAddress, sellAmount, toAssetType, buyAmountMin, data);
    }

    function supply(address assetAddress, uint256 amount) external {
        _supply(assetAddress, amount);
    }

    function withdraw(address assetAddress, uint256 amount) external {
        _withdraw(assetAddress, amount);
    }

    function setRebalanceRules(RebalanceLimit memory rebalanceLimit) external {
        _setRebalanceRules(rebalanceLimit);
    }

    function setUp() public initializer {
        vm.createSelectFork("mainnet");
        initialize(
            address(mainnet.WETH),
            address(mainnet.WBTC),
            address(mainnet.USDT),
            address(mainnet.USDC),
            address(mainnet.AAVE_V3),
            address(mainnet.UNISWAP_V4_ROUTER)
        );
        poolDataProvider = IPoolDataProvider(mainnet.POOL_DATA_PROVIDER);
        poolManager = IPoolManager(mainnet.POOL_MANAGER);
    }

    function addWethToAddress(address to, uint256 amount) public {
        vm.deal(to, amount);
        vm.prank(to);
        Address.sendValue(payable(mainnet.WETH), amount);
    }

    function test_Supply() public {
        addWethToAddress(address(this), 1 ether);
        uint256 balanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        _supply(address(mainnet.WETH), 1 ether);

        uint256 balanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertEq(balanceAfter, balanceBefore - 1 ether);

        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(this));
        // Aave may have small rounding differences, allow up to 10 wei difference
        assertApproxEqAbs(currentATokenBalance, 1 ether, 10);
    }

    function test_SupplyRevertAmountIsZero() public {
        vm.expectRevert(AmountIsZero.selector);
        this.supply(mainnet.WETH, 0);
    }

    function test_SupplyRevertAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        this.supply(address(0), 1 ether);
    }

    function test_Withdraw() public {
        addWethToAddress(address(this), 1 ether);
        _supply(address(mainnet.WETH), 1 ether);
        uint256 balanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        (uint256 aTokenBalance,,,,,,,,) = poolDataProvider.getUserReserveData(address(mainnet.WETH), address(this));
        _withdraw(address(mainnet.WETH), aTokenBalance);
        uint256 balanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertApproxEqAbs(balanceAfter, balanceBefore + 1 ether, 1);
    }

    function test_WithdrawRevertAmountIsZero() public {
        vm.expectRevert(AmountIsZero.selector);
        this.withdraw(mainnet.WETH, 0);
    }

    function test_WithdrawRevertAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        this.withdraw(address(0), 1 ether);
    }

    function test_SetRebalanceRules() public {
        RebalanceLimit memory rebalanceLimit = RebalanceLimit({
            minimalWBTCBalance: 1 * 1e8,
            minimalWETHBalance: 100 * 1e18,
            minimalStableCoinBalance: 100 * 1e6,
            minimalTimestampBetweenRebalances: 30,
            maxRebalancePercentage: 10
        });
        _setRebalanceRules(rebalanceLimit);
        assertEq(rebalanceLimit.minimalWBTCBalance, 1 * 1e8);
        assertEq(rebalanceLimit.minimalWETHBalance, 100 * 1e18);
        assertEq(rebalanceLimit.minimalStableCoinBalance, 100 * 1e6);
        assertEq(rebalanceLimit.minimalTimestampBetweenRebalances, 30);
        assertEq(rebalanceLimit.maxRebalancePercentage, 10);
    }

    function getPoolPrice(PoolKey memory key) internal view returns (uint256) {
        PoolId poolId = PoolIdLibrary.toId(key);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        // price = (sqrtPriceX96 / 2^96)^2 = (sqrtPriceX96^2) / (2^192)
        // Use mulDiv to avoid overflow and maintain precision
        // Calculate price with 18 decimals precision: price = (sqrtPriceX96^2 * 1e18) / (2^192)
        // Use nested mulDiv to avoid overflow: first multiply sqrtPriceX96 * 1e18, then multiply by sqrtPriceX96, then divide by Q192
        uint256 Q192 = 2 ** 192;
        return Math.mulDiv(Math.mulDiv(uint256(sqrtPriceX96), 1e18, 1), uint256(sqrtPriceX96), Q192);
    }

    function test_SwapRevertAmountIsZero() public {
        PoolKey memory poolKey = PoolKey({
            currency0: address(0), currency1: address(mainnet.USDT), fee: 3000, tickSpacing: 60, hooks: address(0)
        });

        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = 0;

        BaseData memory baseData = BaseData({
            amount: sellAmount,
            amountLimit: sellAmount,
            payer: address(this),
            receiver: address(this),
            flags: SwapFlags.SINGLE_SWAP
        });

        bytes memory swapData = abi.encode(baseData, true, poolKey, "");
        vm.expectRevert(AmountIsZero.selector);
        this.swap(address(0), sellAmount, AssetType.USDT, buyAmountMin, swapData);
    }

    function test_SwapRevertInsufficientBalance() public {
        // Ensure test contract has no ETH balance
        vm.deal(address(this), 0);

        PoolKey memory poolKey = PoolKey({
            currency0: address(0), currency1: address(mainnet.USDT), fee: 3000, tickSpacing: 60, hooks: address(0)
        });

        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = 1;

        BaseData memory baseData = BaseData({
            amount: sellAmount,
            amountLimit: buyAmountMin,
            payer: address(this),
            receiver: address(this),
            flags: SwapFlags.SINGLE_SWAP
        });

        bytes memory swapData = abi.encode(baseData, true, poolKey, "");
        vm.expectRevert(InsufficientBalance.selector);
        this.swap(address(0), sellAmount, AssetType.USDT, buyAmountMin, swapData);
    }

    function test_Swap() public {
        PoolKey memory poolKey = PoolKey({
            currency0: address(0), currency1: address(mainnet.USDT), fee: 3000, tickSpacing: 60, hooks: address(0)
        });

        uint256 price = getPoolPrice(poolKey);
        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = Math.mulDiv(price, 95, 100);

        BaseData memory baseData = BaseData({
            amount: sellAmount,
            amountLimit: buyAmountMin,
            payer: address(this),
            receiver: address(this),
            flags: SwapFlags.SINGLE_SWAP
        });

        bytes memory swapData = abi.encode(baseData, true, poolKey, "");
        vm.deal(address(this), 1 ether);
        this.swap(address(0), sellAmount, AssetType.USDT, buyAmountMin, swapData);
    }
}
