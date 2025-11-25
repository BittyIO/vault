// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {Migrator} from "../src/Migrator.sol";

import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {MockVault} from "./mock/MockVault.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AddressZero} from "../src/interfaces/Errors.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";
import {IBeneficiary} from "../src/interfaces/IBeneficiary.sol";
import {MockYieldProvider} from "./mock/MockYieldProvider.sol";
import {MockSwapProvider} from "./mock/MockSwapProvider.sol";
import {IWhiteList} from "../src/interfaces/IWhiteList.sol";

contract BittyVaultMigrateTest is Test {
    BittyVault public bittyVault;
    WETH public mockWETH;
    MockERC20 public mockWBTC;
    MockERC20 public mockUSDT;
    MockERC20 public mockUSDC;
    Migrator public migrator;
    address public grantor;
    address public trustee;
    address public whiteListAddress;

    function setUp() public {
        mockWETH = new WETH();
        mockWBTC = new MockERC20("WBTC", "WBTC", 18);
        mockUSDT = new MockERC20("USDT", "USDT", 18);
        mockUSDC = new MockERC20("USDC", "USDC", 18);
        migrator = new Migrator();
        whiteListAddress = address(new WhiteList());
        grantor = makeAddr("grantor");
        trustee = makeAddr("trustee");

        // Create and initialize current vault
        bittyVault = new BittyVault();
        address[] memory assetAddresses = new address[](2);
        assetAddresses[0] = address(mockWBTC);
        assetAddresses[1] = address(mockWETH);
        address[] memory stableCoinAddresses = new address[](2);
        stableCoinAddresses[0] = address(mockUSDT);
        stableCoinAddresses[1] = address(mockUSDC);
        bittyVault.initialize(
            grantor,
            address(mockWETH),
            whiteListAddress,
            address(migrator),
            assetAddresses,
            stableCoinAddresses,
            new address[](0),
            new address[](0)
        );

        // Set trustee
        vm.prank(grantor);
        bittyVault.setTrustee(trustee);

        // Set manageFee to test struct copying
        vm.prank(trustee);
        IAssetManager.ManageFee memory manageFee = IAssetManager.ManageFee({
            baseFeeAmount: 1000,
            baseFeeDuration: 7 days,
            isBaseFeePercentage: false,
            revenuePercentage: 500, // 5% = 500/10000
            revenueDuration: 30 days
        });
        bittyVault.setManageFee(manageFee);

        // Set rebalanceLimit to test struct copying
        vm.prank(trustee);
        IAssetManager.RebalanceLimit memory rebalanceLimit = IAssetManager.RebalanceLimit({
            minimalStableCoinBalance: 10000 * 1e18,
            minimalTimestampBetweenRebalances: 1 days,
            maxRebalancePercentage: 1000 // 10% = 1000/10000
        });
        bittyVault.setRebalanceRules(rebalanceLimit);

        // Add trigger events to test mapping copying
        address triggerAddress1 = makeAddr("trigger1");
        address triggerAddress2 = makeAddr("trigger2");
        string[] memory eventNames = new string[](2);
        eventNames[0] = "Marriage";
        eventNames[1] = "Graduation";
        IBeneficiary.TriggerEvent[] memory triggerEvents = new IBeneficiary.TriggerEvent[](2);
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: triggerAddress1, amount: 5000 * 1e18, isPercentage: false});
        triggerEvents[1] = IBeneficiary.TriggerEvent({
            triggerAddress: triggerAddress2,
            amount: 1000, // 10% = 1000/10000
            isPercentage: true
        });
        vm.prank(grantor);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);

        // Register version 1 implementation (BittyVault) in migrator
        migrator.setVersionizedVault(address(bittyVault), bytes("v1 args"), true);

        // Create mock vault implementation (version 2)
        MockVault nextVaultImplementation = new MockVault();

        // Register version 2 implementation (MockVault) in migrator
        migrator.setVersionizedVault(address(nextVaultImplementation), bytes("v2 args"), false);
    }

    function test_MigrateSuccess() public {
        // Give current vault some assets
        uint256 wbtcAmount = 1 ether;
        uint256 wethAmount = 2 ether;
        uint256 usdtAmount = 1000 * 1e18;
        uint256 usdcAmount = 2000 * 1e18;
        uint256 ethAmount = 0.5 ether;

        deal(address(mockWBTC), address(bittyVault), wbtcAmount);
        deal(address(mockWETH), address(bittyVault), wethAmount);
        deal(address(mockUSDT), address(bittyVault), usdtAmount);
        deal(address(mockUSDC), address(bittyVault), usdcAmount);
        deal(address(bittyVault), ethAmount);

        // Create next version vault instance
        vm.prank(trustee);
        address nextVaultAddress = migrator.createNextVersionVault("migration-salt", address(bittyVault));

        // Record balances before migration
        uint256 nextVaultWbtcBefore = mockWBTC.balanceOf(nextVaultAddress);
        uint256 nextVaultWethBefore = mockWETH.balanceOf(nextVaultAddress);
        uint256 nextVaultUsdtBefore = mockUSDT.balanceOf(nextVaultAddress);
        uint256 nextVaultUsdcBefore = mockUSDC.balanceOf(nextVaultAddress);
        uint256 nextVaultEthBefore = nextVaultAddress.balance;

        // Execute migration
        vm.prank(trustee);
        bittyVault.migrate();

        // Verify all assets are transferred to next vault
        assertEq(mockWBTC.balanceOf(address(bittyVault)), 0, "WBTC should be transferred");
        assertEq(mockWBTC.balanceOf(nextVaultAddress), nextVaultWbtcBefore + wbtcAmount, "WBTC should be in next vault");

        assertEq(mockWETH.balanceOf(address(bittyVault)), 0, "WETH should be transferred");
        assertEq(mockWETH.balanceOf(nextVaultAddress), nextVaultWethBefore + wethAmount, "WETH should be in next vault");

        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0, "USDT should be transferred");
        assertEq(mockUSDT.balanceOf(nextVaultAddress), nextVaultUsdtBefore + usdtAmount, "USDT should be in next vault");

        assertEq(mockUSDC.balanceOf(address(bittyVault)), 0, "USDC should be transferred");
        assertEq(mockUSDC.balanceOf(nextVaultAddress), nextVaultUsdcBefore + usdcAmount, "USDC should be in next vault");

        assertEq(address(bittyVault).balance, 0, "ETH should be transferred");
        assertEq(nextVaultAddress.balance, nextVaultEthBefore + ethAmount, "ETH should be in next vault");
    }

    function test_MigrateFailsIfNotTrustee() public {
        address nonTrustee = makeAddr("nonTrustee");
        vm.expectRevert("Only trustee");
        vm.prank(nonTrustee);
        bittyVault.migrate();
    }

    function test_MigrateFailsIfNotInitialized() public {
        BittyVault newVault = new BittyVault();
        address newTrustee = makeAddr("newTrustee");
        vm.expectRevert("Trust not initialized");
        vm.prank(newTrustee);
        newVault.migrate();
    }

    function test_MigrateFailsIfNoNextVersion() public {
        // Create a new migrator without version 2 registered
        Migrator newMigrator = new Migrator();
        BittyVault newVault = new BittyVault();
        address[] memory assetAddresses = new address[](2);
        assetAddresses[0] = address(mockWBTC);
        assetAddresses[1] = address(mockWETH);
        address[] memory stableCoinAddresses = new address[](2);
        stableCoinAddresses[0] = address(mockUSDT);
        stableCoinAddresses[1] = address(mockUSDC);
        newVault.initialize(
            grantor,
            address(mockWETH),
            whiteListAddress,
            address(newMigrator),
            assetAddresses,
            stableCoinAddresses,
            new address[](0),
            new address[](0)
        );
        vm.prank(grantor);
        newVault.setTrustee(trustee);

        // Register only version 1, no version 2
        newMigrator.setVersionizedVault(address(newVault), bytes("v1 args"), true);

        vm.expectRevert(Migrator.NoNextVersionVault.selector);
        vm.prank(trustee);
        newVault.migrate();
    }

    function test_MigrateWithEmptyBalances() public {
        // Create next version vault instance
        vm.prank(trustee);
        migrator.createNextVersionVault("migration-salt", address(bittyVault));

        // Migrate without adding any assets to vault
        vm.prank(trustee);
        bittyVault.migrate();

        // Verify all balances are 0
        assertEq(mockWBTC.balanceOf(address(bittyVault)), 0);
        assertEq(mockWETH.balanceOf(address(bittyVault)), 0);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0);
        assertEq(mockUSDC.balanceOf(address(bittyVault)), 0);
        assertEq(address(bittyVault).balance, 0);
    }

    function test_MigrateOnlyTransfersAssetsInSet() public {
        // Create next version vault instance
        vm.prank(trustee);
        address nextVaultAddress = migrator.createNextVersionVault("migration-salt", address(bittyVault));

        // Create a token not in asset list
        MockERC20 randomToken = new MockERC20("RANDOM", "RANDOM", 18);
        uint256 randomAmount = 100 ether;
        deal(address(randomToken), address(bittyVault), randomAmount);

        // Give current vault some assets in the list
        uint256 wbtcAmount = 1 ether;
        deal(address(mockWBTC), address(bittyVault), wbtcAmount);

        // Execute migration
        vm.prank(trustee);
        bittyVault.migrate();

        // Verify assets in list are transferred
        assertEq(mockWBTC.balanceOf(address(bittyVault)), 0, "WBTC should be transferred");
        assertEq(mockWBTC.balanceOf(nextVaultAddress), wbtcAmount, "WBTC should be in next vault");

        // Verify tokens not in list are not transferred (because _revoke only transfers assets in _assets and _stableCoins)
        assertEq(randomToken.balanceOf(address(bittyVault)), randomAmount, "Random token should remain");
    }

    function test_NextVaultPublicStorageMatchesOriginalVault() public {
        // Add yield providers and swap providers to white list
        MockYieldProvider mockYieldProvider1 = new MockYieldProvider();
        MockYieldProvider mockYieldProvider2 = new MockYieldProvider();
        MockSwapProvider mockSwapProvider1 = new MockSwapProvider();
        MockSwapProvider mockSwapProvider2 = new MockSwapProvider();

        address[] memory yieldProviders = new address[](2);
        yieldProviders[0] = address(mockYieldProvider1);
        yieldProviders[1] = address(mockYieldProvider2);

        address[] memory swapProviders = new address[](2);
        swapProviders[0] = address(mockSwapProvider1);
        swapProviders[1] = address(mockSwapProvider2);

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addYieldProviders(yieldProviders);
        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);
        vm.stopPrank();

        // Add yield providers and swap providers to vault
        vm.prank(trustee);
        bittyVault.addYieldProviders(yieldProviders);
        vm.prank(trustee);
        bittyVault.addSwapProviders(swapProviders);

        // Create next version vault instance
        vm.prank(trustee);
        address nextVaultAddress = migrator.createNextVersionVault("migration-salt", address(bittyVault));
        MockVault nextVaultInstance = MockVault(payable(nextVaultAddress));

        assertEq(nextVaultInstance.args(), bytes("v2 args"), "args should match");

        // Verify Trust contract public storage variables
        assertEq(nextVaultInstance.grantor(), bittyVault.grantor(), "grantor should match");
        assertEq(nextVaultInstance.trustee(), bittyVault.trustee(), "trustee should match");
        assertEq(nextVaultInstance.assetManager(), bittyVault.assetManager(), "assetManager should match");
        assertEq(nextVaultInstance.beneficiary(), bittyVault.beneficiary(), "beneficiary should match");
        assertEq(nextVaultInstance.isInitialized(), bittyVault.isInitialized(), "isInitialized should match");
        assertEq(nextVaultInstance.isIrrevocable(), bittyVault.isIrrevocable(), "isIrrevocable should match");
        assertEq(
            nextVaultInstance.autoIrrevocableAfterNoPing(),
            bittyVault.autoIrrevocableAfterNoPing(),
            "autoIrrevocableAfterNoPing should match"
        );
        assertEq(nextVaultInstance.lastPingTime(), bittyVault.lastPingTime(), "lastPingTime should match");
        assertEq(
            nextVaultInstance.autoIrrevocableStartTime(),
            bittyVault.autoIrrevocableStartTime(),
            "autoIrrevocableStartTime should match"
        );
        assertEq(
            nextVaultInstance.lastWithdrawalTime(), bittyVault.lastWithdrawalTime(), "lastWithdrawalTime should match"
        );
        assertEq(
            nextVaultInstance.startDistributionTimestamp(),
            bittyVault.startDistributionTimestamp(),
            "startDistributionTimestamp should match"
        );
        assertEq(nextVaultInstance.lastBaseFeeTime(), bittyVault.lastBaseFeeTime(), "lastBaseFeeTime should match");
        assertEq(nextVaultInstance.revenue(), bittyVault.revenue(), "revenue should match");
        assertEq(nextVaultInstance.lastRevenueTime(), bittyVault.lastRevenueTime(), "lastRevenueTime should match");

        // Verify manageFee struct
        // Both BittyVault and MockVault's public struct getters return tuples, so we destructure both
        (
            uint256 originalBaseFeeAmount,
            uint256 originalBaseFeeDuration,
            bool originalIsBaseFeePercentage,
            uint256 originalRevenuePercentage,
            uint256 originalRevenueDuration
        ) = bittyVault.manageFee();
        (
            uint256 copiedBaseFeeAmount,
            uint256 copiedBaseFeeDuration,
            bool copiedIsBaseFeePercentage,
            uint256 copiedRevenuePercentage,
            uint256 copiedRevenueDuration
        ) = nextVaultInstance.manageFee();
        assertEq(copiedBaseFeeAmount, originalBaseFeeAmount, "manageFee.baseFeeAmount should match");
        assertEq(copiedBaseFeeDuration, originalBaseFeeDuration, "manageFee.baseFeeDuration should match");
        assertEq(copiedIsBaseFeePercentage, originalIsBaseFeePercentage, "manageFee.isBaseFeePercentage should match");
        assertEq(copiedRevenuePercentage, originalRevenuePercentage, "manageFee.revenuePercentage should match");
        assertEq(copiedRevenueDuration, originalRevenueDuration, "manageFee.revenueDuration should match");

        // Verify AssetManager contract public storage variables
        assertEq(nextVaultInstance.wethAddress(), bittyVault.wethAddress(), "wethAddress should match");
        assertEq(address(nextVaultInstance.whiteList()), address(bittyVault.whiteList()), "whiteList should match");
        assertEq(
            nextVaultInstance.lastRebalanceTimestamp(),
            bittyVault.lastRebalanceTimestamp(),
            "lastRebalanceTimestamp should match"
        );

        // Verify rebalanceLimit struct
        // Both BittyVault and MockVault's public struct getters return tuples, so we destructure both
        (
            uint256 originalMinimalStableCoinBalance,
            uint256 originalMinimalTimestampBetweenRebalances,
            uint256 originalMaxRebalancePercentage
        ) = bittyVault.rebalanceLimit();
        (
            uint256 copiedMinimalStableCoinBalance,
            uint256 copiedMinimalTimestampBetweenRebalances,
            uint256 copiedMaxRebalancePercentage
        ) = nextVaultInstance.rebalanceLimit();
        assertEq(
            copiedMinimalStableCoinBalance,
            originalMinimalStableCoinBalance,
            "rebalanceLimit.minimalStableCoinBalance should match"
        );
        assertEq(
            copiedMinimalTimestampBetweenRebalances,
            originalMinimalTimestampBetweenRebalances,
            "rebalanceLimit.minimalTimestampBetweenRebalances should match"
        );
        assertEq(
            copiedMaxRebalancePercentage,
            originalMaxRebalancePercentage,
            "rebalanceLimit.maxRebalancePercentage should match"
        );

        // Verify BittyVault contract public storage variables
        assertEq(address(nextVaultInstance.migrator()), address(bittyVault.migrator()), "migrator should match");

        // Verify beneficiaryTriggerEvents mapping
        // Get keys from original vault and verify values in mock vault
        bytes32[] memory triggerEventKeys = bittyVault.getAllTriggerEventKeys();
        for (uint256 i = 0; i < triggerEventKeys.length; i++) {
            bytes32 eventKey = triggerEventKeys[i];
            (address originalTriggerAddress, uint256 originalAmount, bool originalIsPercentage) =
                bittyVault.beneficiaryTriggerEvents(eventKey);
            (address copiedTriggerAddress, uint256 copiedAmount, bool copiedIsPercentage) =
                nextVaultInstance.beneficiaryTriggerEvents(eventKey);
            assertEq(
                copiedTriggerAddress, originalTriggerAddress, "beneficiaryTriggerEvents triggerAddress should match"
            );
            assertEq(copiedAmount, originalAmount, "beneficiaryTriggerEvents amount should match");
            assertEq(copiedIsPercentage, originalIsPercentage, "beneficiaryTriggerEvents isPercentage should match");
        }

        // Verify beneficiaryTimeEvents mapping
        // Get keys from original vault and verify values in mock vault
        uint256[] memory timeEventKeys = bittyVault.getAllTimeEventKeys();
        for (uint256 i = 0; i < timeEventKeys.length; i++) {
            uint256 timestamp = timeEventKeys[i];
            (uint256 originalAmount, bool originalIsPercentage) = bittyVault.beneficiaryTimeEvents(timestamp);
            (uint256 copiedAmount, bool copiedIsPercentage) = nextVaultInstance.beneficiaryTimeEvents(timestamp);
            assertEq(copiedAmount, originalAmount, "beneficiaryTimeEvents amount should match");
            assertEq(copiedIsPercentage, originalIsPercentage, "beneficiaryTimeEvents isPercentage should match");
        }

        // Verify assetConfigs mapping
        // Get keys from original vault and verify values in mock vault
        address[] memory assetConfigKeys = bittyVault.getAllAssetConfigKeys();
        for (uint256 i = 0; i < assetConfigKeys.length; i++) {
            address assetAddress = assetConfigKeys[i];
            (uint256 originalMinimalBalance, uint256 originalMinimalDuration) = bittyVault.assetConfigs(assetAddress);
            (uint256 copiedMinimalBalance, uint256 copiedMinimalDuration) = nextVaultInstance.assetConfigs(assetAddress);
            assertEq(copiedMinimalBalance, originalMinimalBalance, "assetConfigs minimalBalance should match");
            assertEq(
                copiedMinimalDuration,
                originalMinimalDuration,
                "assetConfigs minimalDurationBetweenRebalances should match"
            );
        }

        // Verify lastRebalanceTimestamps mapping
        // Get keys from original vault and verify values in mock vault
        address[] memory lastRebalanceTimestampKeys = bittyVault.getAllLastRebalanceTimestampKeys();
        for (uint256 i = 0; i < lastRebalanceTimestampKeys.length; i++) {
            address assetAddress = lastRebalanceTimestampKeys[i];
            assertEq(
                nextVaultInstance.lastRebalanceTimestamps(assetAddress),
                bittyVault.lastRebalanceTimestamps(assetAddress),
                "lastRebalanceTimestamps should match"
            );
        }

        // Verify _assets, _stableCoins, _yieldProviders, _swapProviders
        address[] memory originalAssets = bittyVault.getAssets();
        address[] memory copiedAssets = nextVaultInstance.getAssets();
        assertEq(copiedAssets.length, originalAssets.length, "_assets length should match");
        for (uint256 i = 0; i < originalAssets.length; i++) {
            assertEq(copiedAssets[i], originalAssets[i], "_assets should match");
        }

        address[] memory originalStableCoins = bittyVault.getStableCoins();
        address[] memory copiedStableCoins = nextVaultInstance.getStableCoins();
        assertEq(copiedStableCoins.length, originalStableCoins.length, "_stableCoins length should match");
        for (uint256 i = 0; i < originalStableCoins.length; i++) {
            assertEq(copiedStableCoins[i], originalStableCoins[i], "_stableCoins should match");
        }

        address[] memory originalYieldProviders = bittyVault.getYieldProviders();
        address[] memory copiedYieldProviders = nextVaultInstance.getYieldProviders();
        assertEq(copiedYieldProviders.length, originalYieldProviders.length, "_yieldProviders length should match");
        assertEq(copiedYieldProviders.length, 2, "Should have 2 yield providers");
        for (uint256 i = 0; i < originalYieldProviders.length; i++) {
            assertEq(copiedYieldProviders[i], originalYieldProviders[i], "_yieldProviders should match");
        }

        address[] memory originalSwapProviders = bittyVault.getSwapProviders();
        address[] memory copiedSwapProviders = nextVaultInstance.getSwapProviders();
        assertEq(copiedSwapProviders.length, originalSwapProviders.length, "_swapProviders length should match");
        assertEq(copiedSwapProviders.length, 2, "Should have 2 swap providers");
        for (uint256 i = 0; i < originalSwapProviders.length; i++) {
            assertEq(copiedSwapProviders[i], originalSwapProviders[i], "_swapProviders should match");
        }
    }
}

