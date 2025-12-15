// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";
import {
    AmountIsZero,
    RevenueDurationIsZero,
    BaseFeeDurationNotMet,
    RevenuePercentageIsZero,
    RevenueDurationNotMet,
    RevenueIsZero,
    RebalanceInMinimalTime,
    MinimalBalanceNotMet,
    NotWhiteListed,
    AddressZero,
    OnlyAssetManager,
    OnlyTrustee
} from "../src/interfaces/Errors.sol";

import {MockSwapProvider} from "./mock/MockSwapProvider.sol";
import {MockYieldProvider} from "./mock/MockYieldProvider.sol";
import {IYieldProvider, ISwapProvider} from "../src/interfaces/IAssetManager.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {IWhiteList} from "../src/interfaces/IWhiteList.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {Migrator} from "../src/Migrator.sol";
import {AssetManagerLogic} from "../src/logic/AssetManagerLogic.sol";
import {AssetManagerStorage} from "../src/logic/Storages.sol";

contract TestBittyVault is BittyVault {
    using AssetManagerLogic for AssetManagerStorage;

    function cloneProviderForTesting(address provider) external returns (address) {
        return _assetManager.cloneProvider(provider);
    }

    function setRevenueForTesting(uint256 revenueAmount) external {
        _assetManager.revenue = revenueAmount;
    }
}

contract BittyVaultTrusteeTest is Test {
    TestBittyVault public bittyVault;
    WETH public mockWETH;
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
    address public migratorAddress;
    address public poolManagerAddress;

    function setUp() public {
        mockWETH = new WETH();
        mockWBTC = new MockERC20("WBTC", "WBTC", 18);
        mockUSDT = new MockERC20("USDT", "USDT", 18);
        mockUSDC = new MockERC20("USDC", "USDC", 18);
        mockSwapProvider = new MockSwapProvider();
        mockYieldProvider = new MockYieldProvider();
        bittyVault = new TestBittyVault();
        poolManagerAddress = makeAddr("poolManagerAddress");
        whiteListAddress = address(new WhiteList(poolManagerAddress));
        migratorAddress = address(new Migrator());
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
        IWhiteList(whiteListAddress).addAssets(assetAddresses);
        IWhiteList(whiteListAddress).addStableCoins(stableCoinAddresses);
        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);
        IWhiteList(whiteListAddress).addYieldProviders(yieldProviderAddresses);
        bittyVault.initialize(
            grantor,
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
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
        vm.expectRevert(OnlyAssetManager.selector);
        vm.prank(trustee);
        bittyVault.getBaseFee(address(mockUSDT));
    }

    function test_TrusteeGetBaseFeeFailedBeforeDuration() public {
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
        vm.expectRevert(BaseFeeDurationNotMet.selector);
        vm.prank(assetManager);
        bittyVault.getBaseFee(address(mockUSDT));
    }

    function test_TrusteeGetBaseFeeShouldBeFine() public {
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
        deal(address(mockUSDT), address(bittyVault), manageFee.baseFeeAmount * 10 ** mockUSDT.decimals());
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(assetManager);
        bittyVault.getBaseFee(address(mockUSDT));
        assertEq(mockUSDT.balanceOf(assetManager), manageFee.baseFeeAmount * 10 ** mockUSDT.decimals());
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
        bittyVault.getBaseFee(address(mockUSDT));
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
        vm.expectRevert(OnlyAssetManager.selector);
        vm.prank(trustee);
        bittyVault.getRevenueFee(address(mockUSDT));
    }

    function test_TrusteeGetRevenueFailedIfDurationIsNotMet() public {
        manageFee.revenuePercentage = 10;
        manageFee.revenueDuration = 30 days;
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
        uint256 revenueAmount = 1000;
        bittyVault.setRevenueForTesting(revenueAmount);

        // First, call getRevenueFee successfully to set lastRevenueTime
        uint256 expectedFeeBase = revenueAmount * manageFee.revenuePercentage / 10000;
        uint256 expectedFeeTokens = expectedFeeBase * 10 ** mockUSDT.decimals();
        deal(address(mockUSDT), address(bittyVault), expectedFeeTokens);
        vm.warp(block.timestamp + manageFee.revenueDuration + 1);
        vm.prank(assetManager);
        bittyVault.getRevenueFee(address(mockUSDT));

        // Now set revenue again and test duration check
        bittyVault.setRevenueForTesting(revenueAmount);
        deal(address(mockUSDT), address(bittyVault), expectedFeeTokens);
        vm.warp(block.timestamp + manageFee.revenueDuration - 1);
        vm.prank(assetManager);
        vm.expectRevert(RevenueDurationNotMet.selector);
        bittyVault.getRevenueFee(address(mockUSDT));
    }

    function test_TrusteeGetRevenueFeeFailedIfRevenueIsZero() public {
        manageFee.revenuePercentage = 10;
        manageFee.revenueDuration = 30 days;
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);
        vm.warp(block.timestamp + manageFee.revenueDuration + 1);
        vm.prank(assetManager);
        vm.expectRevert(RevenueIsZero.selector);
        bittyVault.getRevenueFee(address(mockUSDT));
    }

    function test_TrusteeGetRevenueFeeSuccess() public {
        manageFee.revenuePercentage = 10;
        manageFee.revenueDuration = 30 days;
        vm.prank(trustee);
        bittyVault.setManageFee(manageFee);

        uint256 revenueAmount = 1000;
        bittyVault.setRevenueForTesting(revenueAmount);

        uint256 expectedFeeBase = revenueAmount * manageFee.revenuePercentage / 10000;
        uint256 expectedFeeTokens = expectedFeeBase * 10 ** mockUSDT.decimals();

        deal(address(mockUSDT), address(bittyVault), expectedFeeTokens);

        vm.warp(block.timestamp + manageFee.revenueDuration + 1);
        vm.prank(assetManager);
        bittyVault.getRevenueFee(address(mockUSDT));

        assertEq(mockUSDT.balanceOf(assetManager), expectedFeeTokens);
        assertEq(bittyVault.revenue(), 0);
    }

    function test_ChangeTrusteeAddress_Success() public {
        address newTrustee = makeAddr("newTrustee");
        vm.prank(trustee);
        bittyVault.changeTrusteeAddress(newTrustee);
        assertEq(bittyVault.trustee(), newTrustee);
    }

    function test_ChangeTrusteeAddress_RevertsIfAddressZero() public {
        vm.prank(trustee);
        vm.expectRevert(AddressZero.selector);
        bittyVault.changeTrusteeAddress(address(0));
    }

    function test_ChangeTrusteeAddress_RevertsIfNotTrustee() public {
        address unauthorized = makeAddr("unauthorized");
        address newTrustee = makeAddr("newTrustee");
        vm.prank(unauthorized);
        vm.expectRevert(OnlyTrustee.selector);
        bittyVault.changeTrusteeAddress(newTrustee);
    }

    function test_RebalanceFailedIfNotFromAssetManager() public {
        uint256 sellAmount = 1 * 1e6;
        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);
        address wethAddress = bittyVault.getAssets()[1];
        address usdtAddress = bittyVault.getStableCoins()[0];
        vm.expectRevert(OnlyAssetManager.selector);
        vm.prank(trustee);
        bittyVault.rebalance(address(mockSwapProvider), wethAddress, usdtAddress, sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFailedIfRebalanceIsZero() public {
        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances + 1);
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), address(mockWETH), address(mockUSDT), 0, 100 * 1e6, "");
    }

    function test_RebalanceFailedIfRebalanceInMinimalTime() public {
        uint256 sellAmount = 1 * 1e6;
        uint256 buyAmount = 10 * 1e6;

        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);
        address wethAddress = bittyVault.getAssets()[1];
        address usdtAddress = bittyVault.getStableCoins()[0];

        address clonedSwapProvider = bittyVault.cloneProviderForTesting(address(mockSwapProvider));
        require(clonedSwapProvider != address(0), "Provider should be cloned");

        deal(address(mockWETH), address(bittyVault), sellAmount);
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        vm.prank(address(bittyVault));
        mockWETH.approve(clonedSwapProvider, sellAmount);

        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances + 1);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), wethAddress, usdtAddress, sellAmount, buyAmount, swapData);

        deal(address(mockWETH), address(bittyVault), sellAmount);
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        vm.prank(address(bittyVault));
        mockWETH.approve(clonedSwapProvider, sellAmount);

        vm.expectRevert(RebalanceInMinimalTime.selector);
        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances - 1);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), wethAddress, usdtAddress, sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFailedIfMinimalWBTCBalanceIsNotMet() public {
        uint256 sellAmount = 1;
        uint256 buyAmount = 10 * 1e6;
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
        uint256 buyAmount = 10 * 1e6;
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
        uint256 buyAmount = 1;
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

        bytes memory swapData = abi.encode(address(mockUSDT), sellAmount, address(mockUSDC), buyAmount);
        address usdtAddress = bittyVault.getStableCoins()[0];
        address usdcAddress = bittyVault.getStableCoins()[1];

        address clonedSwapProvider = bittyVault.cloneProviderForTesting(address(mockSwapProvider));
        require(clonedSwapProvider != address(0), "Provider should be cloned");

        deal(address(mockUSDC), clonedSwapProvider, buyAmount);
        vm.prank(address(bittyVault));
        mockUSDT.approve(clonedSwapProvider, sellAmount);

        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances + 1);
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

    function test_RemoveYieldProviderShouldBeFine() public {
        address[] memory yieldProviderAddresses = new address[](1);
        yieldProviderAddresses[0] = address(mockYieldProvider);
        vm.prank(trustee);
        bittyVault.addYieldProviders(yieldProviderAddresses);
        vm.prank(trustee);
        bittyVault.removeYieldProviders(yieldProviderAddresses);
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

    function test_RebalanceFailedIfInvalidSwapData() public {
        uint256 sellAmount = 1 * 1e6;
        uint256 buyAmount = 10 * 1e6;
        // Invalid swap data - wrong sell token
        bytes memory swapData = abi.encode(address(mockUSDT), sellAmount, address(mockWETH), buyAmount);
        address wethAddress = bittyVault.getAssets()[1];
        address usdtAddress = bittyVault.getStableCoins()[0];
        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances + 1);
        vm.expectRevert();
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), wethAddress, usdtAddress, sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFailedIfAssetConfigMinimalDurationNotMet() public {
        uint256 sellAmount = 1 * 1e6;
        uint256 buyAmount = 10 * 1e6;
        uint256 minimalDuration = 60;

        vm.prank(trustee);
        bittyVault.setAssetConfig(
            address(mockWETH),
            IAssetManager.AssetConfig({minimalBalance: 0, minimalDurationBetweenRebalances: minimalDuration})
        );

        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);
        address wethAddress = address(mockWETH);
        address usdtAddress = address(mockUSDT);

        address clonedSwapProvider = bittyVault.cloneProviderForTesting(address(mockSwapProvider));
        deal(address(mockWETH), address(bittyVault), sellAmount);
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        vm.prank(address(bittyVault));
        mockWETH.approve(clonedSwapProvider, sellAmount);

        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances + 1);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), wethAddress, usdtAddress, sellAmount, buyAmount, swapData);

        // Try to rebalance again before minimal duration
        deal(address(mockWETH), address(bittyVault), sellAmount);
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        vm.prank(address(bittyVault));
        mockWETH.approve(clonedSwapProvider, sellAmount);

        vm.expectRevert(RebalanceInMinimalTime.selector);
        vm.warp(block.timestamp + minimalDuration - 1);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), wethAddress, usdtAddress, sellAmount, buyAmount, swapData);
    }

    function test_RebalanceSuccessAfterAssetConfigMinimalDuration() public {
        uint256 sellAmount = 1 * 1e6;
        uint256 buyAmount = 10 * 1e6;
        uint256 minimalDuration = 60;

        vm.prank(trustee);
        bittyVault.setAssetConfig(
            address(mockWETH),
            IAssetManager.AssetConfig({minimalBalance: 0, minimalDurationBetweenRebalances: minimalDuration})
        );

        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);
        address wethAddress = address(mockWETH);
        address usdtAddress = address(mockUSDT);

        address clonedSwapProvider = bittyVault.cloneProviderForTesting(address(mockSwapProvider));
        deal(address(mockWETH), address(bittyVault), sellAmount);
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        vm.prank(address(bittyVault));
        mockWETH.approve(clonedSwapProvider, sellAmount);

        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances + 1);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), wethAddress, usdtAddress, sellAmount, buyAmount, swapData);

        // Rebalance again after minimal duration
        deal(address(mockWETH), address(bittyVault), sellAmount);
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        vm.prank(address(bittyVault));
        mockWETH.approve(clonedSwapProvider, sellAmount);

        vm.warp(block.timestamp + minimalDuration + 1);
        vm.prank(assetManager);
        bittyVault.rebalance(address(mockSwapProvider), wethAddress, usdtAddress, sellAmount, buyAmount, swapData);
    }

    function test_GetAllAssetConfigKeys() public {
        IAssetManager.AssetConfig memory assetConfig1 =
            IAssetManager.AssetConfig({minimalBalance: 100 * 1e6, minimalDurationBetweenRebalances: 30});
        IAssetManager.AssetConfig memory assetConfig2 =
            IAssetManager.AssetConfig({minimalBalance: 200 * 1e6, minimalDurationBetweenRebalances: 60});

        vm.prank(trustee);
        bittyVault.setAssetConfig(address(mockWBTC), assetConfig1);
        vm.prank(trustee);
        bittyVault.setAssetConfig(address(mockWETH), assetConfig2);

        address[] memory keys = bittyVault.getAllAssetConfigKeys();
        assertEq(keys.length, 2);
        assertTrue(keys[0] == address(mockWBTC) || keys[1] == address(mockWBTC));
        assertTrue(keys[0] == address(mockWETH) || keys[1] == address(mockWETH));
    }

    function test_GetAllLastRebalanceTimestampKeys() public {
        IAssetManager.AssetConfig memory assetConfig =
            IAssetManager.AssetConfig({minimalBalance: 0, minimalDurationBetweenRebalances: 30});
        vm.prank(trustee);
        bittyVault.setAssetConfig(address(mockWETH), assetConfig);

        uint256 sellAmount = 1 * 1e6;
        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        address clonedSwapProvider = bittyVault.cloneProviderForTesting(address(mockSwapProvider));
        deal(address(mockWETH), address(bittyVault), sellAmount);
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        vm.prank(address(bittyVault));
        mockWETH.approve(clonedSwapProvider, sellAmount);

        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances + 1);
        vm.prank(assetManager);
        bittyVault.rebalance(
            address(mockSwapProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData
        );

        address[] memory keys = bittyVault.getAllLastRebalanceTimestampKeys();
        assertEq(keys.length, 1);
        assertEq(keys[0], address(mockWETH));
    }

    function test_RemoveSwapProviders() public {
        address[] memory swapProviderAddresses = new address[](1);
        swapProviderAddresses[0] = address(mockSwapProvider);
        vm.prank(trustee);
        bittyVault.addSwapProviders(swapProviderAddresses);

        address[] memory providers = bittyVault.getSwapProviders();
        assertEq(providers.length, 1);

        vm.prank(trustee);
        bittyVault.removeSwapProviders(swapProviderAddresses);

        providers = bittyVault.getSwapProviders();
        assertEq(providers.length, 0);
    }
}
