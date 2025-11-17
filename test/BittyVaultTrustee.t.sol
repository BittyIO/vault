// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {ITrust} from "../src/interfaces/ITrust.sol";
import {ITrustee} from "../src/interfaces/ITrustee.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";

import {
    AmountIsZero,
    RevenueDurationIsZero,
    BaseFeeDurationNotMet,
    RevenuePercentageIsZero,
    RevenueDurationNotMet,
    RebalanceInMinimalTime,
    MinimalWBTCBalanceLimit,
    MinimalWETHBalanceLimit,
    MinimalStableCoinBalanceLimit
} from "../src/interfaces/Errors.sol";

import {MockSwapProvider} from "./mock/MockSwapProvider.sol";
import {ISwapProvider} from "../src/interfaces/IAssetManager.sol";
import {MockWETH} from "./mock/MockWETH.sol";
import {MockERC20} from "./mock/MockERC20.sol";

interface IWETH {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
}

contract BittyVaultTrusteeTest is Test {
    BittyVault public bittyVault;
    MockWETH public mockWETH;
    MockERC20 public mockWBTC;
    MockERC20 public mockUSDT;
    MockERC20 public mockUSDC;
    ISwapProvider public mockSwapProvider;
    address public trustee;
    address public assetManager;
    IAssetManager.RebalanceLimit public rebalanceLimits;
    IAssetManager.ManageFee public manageFee;

    function setUp() public {
        mockWETH = new MockWETH();
        mockWBTC = new MockERC20("WBTC", "WBTC", 18);
        mockUSDT = new MockERC20("USDT", "USDT", 18);
        mockUSDC = new MockERC20("USDC", "USDC", 18);
        mockSwapProvider = new MockSwapProvider();
        bittyVault = new BittyVault();
        trustee = makeAddr("alice");
        assetManager = makeAddr("bob");
        vm.prank(trustee);
        bittyVault.initialize(
            address(this),
            address(mockWETH),
            address(mockWBTC),
            address(mockUSDT),
            address(mockUSDC),
            address(0),
            address(mockSwapProvider)
        );
        bittyVault.setTrustee(trustee);
        vm.prank(trustee);
        bittyVault.setAssetManager(assetManager);
        rebalanceLimits = IAssetManager.RebalanceLimit({
            minimalWBTCBalance: 1 * 1e8,
            minimalWETHBalance: 100 * 1e18,
            minimalStableCoinBalance: 100 * 1e6,
            minimalTimestampBetweenRebalances: 30,
            maxRebalancePercentage: 10
        });
        vm.prank(trustee);
        bittyVault.setRebalanceRules(rebalanceLimits);
        manageFee = IAssetManager.ManageFee({
            baseFeeAmount: 100 * 1e6,
            baseFeeDuration: 30 days,
            isBaseFeePercentage: false,
            revenuePercentage: 0,
            revenueDuration: 0
        });
    }

    function test_SetManageFeeFailedIfAmountIsZero() public {
        manageFee.baseFeeAmount = 0;
        manageFee.revenuePercentage = 0;
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
    }

    function test_SetManageFeeFailedIfRevenueDurationIsZero() public {
        manageFee.revenueDuration = 0;
        manageFee.revenuePercentage = 10;
        vm.expectRevert(RevenueDurationIsZero.selector);
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
    }

    function test_GetBaseFeeFailedIfNotFromAssetManager() public {
        vm.expectRevert("Only asset manager");
        vm.prank(trustee);
        bittyVault.getBaseFee();
    }

    function test_TrusteeGetBaseFeeFailedBeforeDuration() public {
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
        vm.expectRevert(BaseFeeDurationNotMet.selector);
        vm.prank(assetManager);
        bittyVault.getBaseFee();
    }

    function test_TrusteeGetBaseFeeShouldBeFine() public {
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
        deal(address(mockUSDT), address(bittyVault), manageFee.baseFeeAmount);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(assetManager);
        bittyVault.getBaseFee();
        assertEq(mockUSDT.balanceOf(assetManager), manageFee.baseFeeAmount);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0);
    }

    function test_TrusteeGetBaseFeeShouldBeFineByPercentage() public {
        manageFee.isBaseFeePercentage = true;
        manageFee.baseFeeAmount = 1000;
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
        deal(address(mockUSDT), address(bittyVault), 100 * 1e6);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(assetManager);
        bittyVault.getBaseFee();
        assertEq(mockUSDT.balanceOf(assetManager), 10 * 1e6);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 90 * 1e6);
    }

    function test_TrusteeGetRevenueFeeFailedIfRevenuePercentageIsZero() public {
        manageFee.revenuePercentage = 0;
        manageFee.revenueDuration = 30 days;
        vm.expectRevert(RevenuePercentageIsZero.selector);
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
    }

    function test_TrusteeGetRevenueFeeFailedIfNotFromAssetManager() public {
        manageFee.revenuePercentage = 10;
        manageFee.revenueDuration = 30 days;
        vm.expectRevert("Only asset manager");
        vm.prank(trustee);
        bittyVault.getRevenueFee();
    }

    function test_TrusteeGetRevenueFailedIfDurationIsNotMet() public {
        manageFee.revenuePercentage = 10;
        manageFee.revenueDuration = 30 days;
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
        vm.warp(block.timestamp + manageFee.revenueDuration - 1);
        vm.prank(assetManager);
        vm.expectRevert(RevenueDurationNotMet.selector);
        bittyVault.getRevenueFee();
    }

    function test_RebalanceFailedIfNotFromAssetManager() public {
        uint256 sellAmount = 1 * 1e6;
        deal(address(mockUSDT), address(bittyVault), rebalanceLimits.minimalStableCoinBalance);
        deal(address(mockWETH), address(bittyVault), rebalanceLimits.minimalWETHBalance + 2 * sellAmount);
        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), address(mockSwapProvider), buyAmount);
        vm.prank(address(bittyVault));
        mockWETH.approve(address(mockSwapProvider), sellAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);
        vm.expectRevert("Only asset manager");
        vm.prank(trustee);
        bittyVault.rebalance(
            IAssetManager.AssetType.WETH, IAssetManager.AssetType.USDT, sellAmount, buyAmount, swapData
        );
    }

    function test_RebalanceFailedIfRebalanceIsZero() public {
        deal(address(mockWETH), address(bittyVault), rebalanceLimits.minimalWETHBalance);
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManager);
        bittyVault.rebalance(IAssetManager.AssetType.WETH, IAssetManager.AssetType.USDT, 0, 100 * 1e6, "");
    }

    function test_RebalanceFailedIfRebalanceInMinimalTime() public {
        uint256 sellAmount = 1 * 1e6;
        deal(address(mockUSDT), address(bittyVault), rebalanceLimits.minimalStableCoinBalance);
        deal(address(mockWETH), address(bittyVault), rebalanceLimits.minimalWETHBalance + 2 * sellAmount);
        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), address(mockSwapProvider), buyAmount);

        vm.prank(address(bittyVault));
        mockWETH.approve(address(mockSwapProvider), sellAmount);

        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);
        vm.warp(block.timestamp + 30 + 1);
        vm.prank(assetManager);
        bittyVault.rebalance(
            IAssetManager.AssetType.WETH, IAssetManager.AssetType.USDT, sellAmount, buyAmount, swapData
        );

        deal(address(mockUSDT), address(mockSwapProvider), buyAmount);

        vm.expectRevert(RebalanceInMinimalTime.selector);
        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances - 1);
        vm.prank(assetManager);
        bittyVault.rebalance(
            IAssetManager.AssetType.WETH, IAssetManager.AssetType.USDT, sellAmount, buyAmount, swapData
        );
    }

    function test_RebalanceFailedIfMinimalWBTCBalanceIsNotMet() public {
        uint256 sellAmount = rebalanceLimits.minimalWBTCBalance;
        deal(address(mockWBTC), address(bittyVault), rebalanceLimits.minimalWBTCBalance);

        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), address(mockSwapProvider), buyAmount);

        vm.prank(address(bittyVault));
        mockWBTC.approve(address(mockSwapProvider), sellAmount);

        bytes memory swapData = abi.encode(address(mockWBTC), sellAmount, address(mockUSDT), buyAmount);
        vm.expectRevert(MinimalWBTCBalanceLimit.selector);
        vm.prank(assetManager);
        bittyVault.rebalance(
            IAssetManager.AssetType.WBTC, IAssetManager.AssetType.USDT, sellAmount, buyAmount, swapData
        );
    }

    function test_RebalanceFailedIfMinimalWETHBalanceIsNotMet() public {
        uint256 sellAmount = 1;
        deal(address(mockWETH), address(bittyVault), rebalanceLimits.minimalWETHBalance);

        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), address(mockSwapProvider), buyAmount);

        vm.prank(address(bittyVault));
        mockWETH.approve(address(mockSwapProvider), sellAmount);

        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);
        vm.expectRevert(MinimalWETHBalanceLimit.selector);
        vm.prank(assetManager);
        bittyVault.rebalance(
            IAssetManager.AssetType.WETH, IAssetManager.AssetType.USDT, sellAmount, buyAmount, swapData
        );
    }

    function test_RebalanceFailedIfMinimalStableCoinBalanceIsNotMet() public {
        uint256 sellAmount = 1;
        deal(address(mockUSDT), address(bittyVault), rebalanceLimits.minimalStableCoinBalance);

        uint256 buyAmount = 1;
        deal(address(mockWETH), address(mockSwapProvider), buyAmount);

        vm.prank(address(bittyVault));
        mockUSDT.approve(address(mockSwapProvider), sellAmount);

        bytes memory swapData = abi.encode(address(mockUSDT), sellAmount, address(mockWETH), buyAmount);
        vm.expectRevert(MinimalStableCoinBalanceLimit.selector);
        vm.prank(assetManager);
        bittyVault.rebalance(
            IAssetManager.AssetType.USDT, IAssetManager.AssetType.WETH, sellAmount, buyAmount, swapData
        );
    }

    function test_RebalanceBetweenStableCoinsShouldBeFine() public {
        uint256 sellAmount = 1;
        deal(address(mockUSDT), address(bittyVault), rebalanceLimits.minimalStableCoinBalance);

        uint256 buyAmount = 1;
        deal(address(mockUSDC), address(mockSwapProvider), buyAmount);

        vm.prank(address(bittyVault));
        mockUSDT.approve(address(mockSwapProvider), sellAmount);

        bytes memory swapData = abi.encode(address(mockUSDT), sellAmount, address(mockUSDC), buyAmount);
        vm.prank(assetManager);
        bittyVault.rebalance(
            IAssetManager.AssetType.USDT, IAssetManager.AssetType.USDC, sellAmount, buyAmount, swapData
        );
        assertEq(mockUSDT.balanceOf(address(bittyVault)), rebalanceLimits.minimalStableCoinBalance - sellAmount);
        assertEq(mockUSDC.balanceOf(address(bittyVault)), buyAmount);
    }
}
