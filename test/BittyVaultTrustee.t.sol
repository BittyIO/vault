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
    MinimalBalanceNotMet,
    NotWhiteListed
} from "../src/interfaces/Errors.sol";

import {MockSwapProvider} from "./mock/MockSwapProvider.sol";
import {MockYieldProvider} from "./mock/MockYieldProvider.sol";
import {IYieldProvider, ISwapProvider} from "../src/interfaces/IAssetManager.sol";
import {MockWETH} from "./mock/MockWETH.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {IWhiteList} from "../src/interfaces/IWhiteList.sol";
import {WhiteList} from "../src/WhiteList.sol";

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
    IYieldProvider public mockYieldProvider;
    ISwapProvider public mockSwapProvider;
    address public grantor;
    address public trustee;
    address public assetManager;
    IAssetManager.RebalanceLimit public rebalanceLimits;
    IAssetManager.ManageFee public manageFee;
    address public whiteListAddress;

    function setUp() public {
        mockWETH = new MockWETH();
        mockWBTC = new MockERC20("WBTC", "WBTC", 18);
        mockUSDT = new MockERC20("USDT", "USDT", 18);
        mockUSDC = new MockERC20("USDC", "USDC", 18);
        mockSwapProvider = new MockSwapProvider();
        mockYieldProvider = new MockYieldProvider();
        bittyVault = new BittyVault();
        whiteListAddress = address(new WhiteList());
        grantor = makeAddr("grantor");
        trustee = makeAddr("alice");
        assetManager = makeAddr("bob");
        address[] memory assetAddresses = new address[](2);
        assetAddresses[0] = address(mockWBTC);
        assetAddresses[1] = address(mockWETH);
        address[] memory stableCoinAddresses = new address[](2);
        stableCoinAddresses[0] = address(mockUSDT);
        stableCoinAddresses[1] = address(mockUSDC);
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = address(mockSwapProvider);
        address[] memory yieldProviderAddresses = new address[](1);
        yieldProviderAddresses[0] = address(mockYieldProvider);
        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addAssets(assetAddresses);
        IWhiteList(whiteListAddress).addStableCoins(stableCoinAddresses);
        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);
        IWhiteList(whiteListAddress).addYieldProviders(yieldProviderAddresses);
        vm.stopPrank();
        bittyVault.initialize(
            grantor,
            address(mockWETH),
            whiteListAddress,
            assetAddresses,
            stableCoinAddresses,
            new address[](0),
            swapProviders
        );
        vm.prank(grantor);
        bittyVault.setTrustee(trustee);
        vm.prank(trustee);
        bittyVault.setAssetManager(assetManager);
        rebalanceLimits = IAssetManager.RebalanceLimit({
            minimalStableCoinBalance: 100 * 1e6, minimalTimestampBetweenRebalances: 30, maxRebalancePercentage: 10
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
        bittyVault.getBaseFee(address(mockUSDT), assetManager);
    }

    function test_TrusteeGetBaseFeeFailedBeforeDuration() public {
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
        vm.expectRevert(BaseFeeDurationNotMet.selector);
        vm.prank(assetManager);
        bittyVault.getBaseFee(address(mockUSDT), assetManager);
    }

    function test_TrusteeGetBaseFeeShouldBeFine() public {
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
        deal(address(mockUSDT), address(bittyVault), manageFee.baseFeeAmount);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(assetManager);
        bittyVault.getBaseFee(address(mockUSDT), assetManager);
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
        bittyVault.getBaseFee(address(mockUSDT), assetManager);
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
        bittyVault.getRevenueFee(address(mockUSDT), assetManager);
    }

    function test_TrusteeGetRevenueFailedIfDurationIsNotMet() public {
        manageFee.revenuePercentage = 10;
        manageFee.revenueDuration = 30 days;
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
        vm.warp(block.timestamp + manageFee.revenueDuration - 1);
        vm.prank(assetManager);
        vm.expectRevert(RevenueDurationNotMet.selector);
        bittyVault.getRevenueFee(address(mockUSDT), assetManager);
    }

    function test_RebalanceFailedIfNotFromAssetManager() public {
        uint256 sellAmount = 1 * 1e6;
        deal(address(mockUSDT), address(bittyVault), rebalanceLimits.minimalStableCoinBalance);
        deal(address(mockWETH), address(bittyVault), 1 ether + 2 * sellAmount);
        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), address(mockSwapProvider), buyAmount);
        vm.prank(address(bittyVault));
        mockWETH.approve(address(mockSwapProvider), sellAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);
        address wethAddress = bittyVault.getAssets()[1];
        address usdtAddress = bittyVault.getStableCoins()[0];
        vm.expectRevert("Only asset manager");
        vm.prank(trustee);
        bittyVault.rebalance(address(mockSwapProvider), wethAddress, usdtAddress, sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFailedIfRebalanceIsZero() public {
        deal(address(mockWETH), address(bittyVault), 1 ether);
        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances + 1);
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), address(mockWETH), address(mockUSDT), 0, 100 * 1e6, "");
    }

    function test_RebalanceFailedIfRebalanceInMinimalTime() public {
        uint256 sellAmount = 1 * 1e6;
        deal(address(mockUSDT), address(bittyVault), rebalanceLimits.minimalStableCoinBalance);
        deal(address(mockWETH), address(bittyVault), 1 ether + 2 * sellAmount);
        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), address(mockSwapProvider), buyAmount);

        vm.prank(address(bittyVault));
        mockWETH.approve(address(mockSwapProvider), sellAmount);

        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);
        address wethAddress = bittyVault.getAssets()[1];
        address usdtAddress = bittyVault.getStableCoins()[0];
        vm.warp(block.timestamp + 30 + 1);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), wethAddress, usdtAddress, sellAmount, buyAmount, swapData);

        deal(address(mockUSDT), address(mockSwapProvider), buyAmount);

        vm.expectRevert(RebalanceInMinimalTime.selector);
        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances - 1);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), wethAddress, usdtAddress, sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFailedIfMinimalWBTCBalanceIsNotMet() public {
        uint256 sellAmount = 1;
        deal(address(mockWBTC), address(bittyVault), 1);

        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), address(mockSwapProvider), buyAmount);

        vm.prank(address(bittyVault));
        mockWBTC.approve(address(mockSwapProvider), sellAmount);

        vm.prank(trustee);
        bittyVault.setAssetConfig(
            address(mockWBTC),
            IAssetManager.AssetConfig({minimalBalance: sellAmount, minimalDurationBetweenRebalances: 0})
        );

        bytes memory swapData = abi.encode(address(mockWBTC), sellAmount, address(mockUSDT), buyAmount);
        address wbtcAddress = address(mockWBTC);
        address usdtAddress = address(mockUSDT);
        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances + 1);
        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), wbtcAddress, usdtAddress, sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFailedIfMinimalWETHBalanceIsNotMet() public {
        uint256 sellAmount = 1;
        deal(address(mockWETH), address(bittyVault), 1 ether);

        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), address(mockSwapProvider), buyAmount);

        vm.prank(address(bittyVault));
        mockWETH.approve(address(mockSwapProvider), sellAmount);

        vm.prank(trustee);
        bittyVault.setAssetConfig(
            address(mockWETH), IAssetManager.AssetConfig({minimalBalance: 1 ether, minimalDurationBetweenRebalances: 0})
        );

        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);
        address wethAddress = address(mockWETH);
        address usdtAddress = address(mockUSDT);
        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances + 1);
        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), wethAddress, usdtAddress, sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFailedIfMinimalStableCoinBalanceIsNotMet() public {
        uint256 sellAmount = 1;
        deal(address(mockUSDT), address(bittyVault), rebalanceLimits.minimalStableCoinBalance);

        uint256 buyAmount = 1;
        deal(address(mockWETH), address(mockSwapProvider), buyAmount);

        vm.prank(address(bittyVault));
        mockUSDT.approve(address(mockSwapProvider), sellAmount);

        bytes memory swapData = abi.encode(address(mockUSDT), sellAmount, address(mockWETH), buyAmount);
        address usdtAddress = address(mockUSDT);
        address wethAddress = address(mockWETH);
        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances + 1);
        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), usdtAddress, wethAddress, sellAmount, buyAmount, swapData);
    }

    function test_RebalanceBetweenStableCoinsShouldBeFine() public {
        uint256 sellAmount = 1;
        deal(address(mockUSDT), address(bittyVault), rebalanceLimits.minimalStableCoinBalance + sellAmount);

        uint256 buyAmount = 1;
        deal(address(mockUSDC), address(mockSwapProvider), buyAmount);

        vm.prank(address(bittyVault));
        mockUSDT.approve(address(mockSwapProvider), sellAmount);

        bytes memory swapData = abi.encode(address(mockUSDT), sellAmount, address(mockUSDC), buyAmount);
        address usdtAddress = bittyVault.getStableCoins()[0];
        address usdcAddress = bittyVault.getStableCoins()[1];
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), usdtAddress, usdcAddress, sellAmount, buyAmount, swapData);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), rebalanceLimits.minimalStableCoinBalance);
        assertEq(mockUSDC.balanceOf(address(bittyVault)), buyAmount);
    }

    function test_AddAssetFailedIfNotInWhiteList() public {
        address[] memory assetAddresses = new address[](1);
        assetAddresses[0] = address(new MockERC20("Test", "TEST", 18));
        vm.expectRevert(NotWhiteListed.selector);
        vm.prank(trustee);
        bittyVault.addAssets(assetAddresses);
    }

    function test_AddAssetShouldBeFine() public {
        address[] memory assetAddresses = new address[](1);
        assetAddresses[0] = address(mockWBTC);
        vm.prank(trustee);
        bittyVault.addAssets(assetAddresses);
        assertEq(bittyVault.getAssets()[0], address(mockWBTC));
    }

    function test_AddStableCoinFailedIfNotInWhiteList() public {
        address[] memory stableCoinAddresses = new address[](1);
        stableCoinAddresses[0] = address(new MockERC20("Test", "TEST", 18));
        vm.expectRevert(NotWhiteListed.selector);
        vm.prank(trustee);
        bittyVault.addStableCoins(stableCoinAddresses);
    }

    function test_AddStableCoinShouldBeFine() public {
        address[] memory stableCoinAddresses = new address[](1);
        stableCoinAddresses[0] = address(mockUSDT);
        vm.prank(trustee);
        bittyVault.addStableCoins(stableCoinAddresses);
        assertEq(bittyVault.getStableCoins()[0], address(mockUSDT));
    }

    function test_AddYieldProviderFailedIfNotInWhiteList() public {
        address[] memory yieldProviderAddresses = new address[](1);
        yieldProviderAddresses[0] = makeAddr("InvalidYieldProvider");
        vm.expectRevert(NotWhiteListed.selector);
        vm.prank(trustee);
        bittyVault.addYieldProviders(yieldProviderAddresses);
    }

    function test_AddYieldProviderShouldBeFine() public {
        address[] memory yieldProviderAddresses = new address[](1);
        yieldProviderAddresses[0] = address(mockYieldProvider);
        vm.prank(trustee);
        bittyVault.addYieldProviders(yieldProviderAddresses);
    }

    function test_AddSwapProviderFailedIfNotInWhiteList() public {
        address[] memory swapProviderAddresses = new address[](1);
        swapProviderAddresses[0] = makeAddr("InvalidSwapProvider");
        vm.expectRevert(NotWhiteListed.selector);
        vm.prank(trustee);
        bittyVault.addSwapProviders(swapProviderAddresses);
    }

    function test_AddSwapProviderShouldBeFine() public {
        address[] memory swapProviderAddresses = new address[](1);
        swapProviderAddresses[0] = address(mockSwapProvider);
        vm.prank(trustee);
        bittyVault.addSwapProviders(swapProviderAddresses);
    }
}
