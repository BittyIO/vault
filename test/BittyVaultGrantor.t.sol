// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {
    AddressZero,
    NotWhiteListed,
    AlreadyInitialized,
    StartDistributionTimestampAlreadySet
} from "../src/interfaces/Errors.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {Migrator} from "../src/Migrator.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";
import {IWhiteList} from "../src/interfaces/IWhiteList.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {MockVault} from "./mock/MockVault.sol";

contract BittyVaultGrantorTest is Test {
    BittyVault public bittyVault;
    WETH public mockWETH;
    address public whiteListAddress;
    address public migratorAddress;
    address public poolManagerAddress;

    function setUp() public {
        mockWETH = new WETH();
        bittyVault = new BittyVault();
        whiteListAddress = address(new WhiteList());
        migratorAddress = address(new Migrator());
        poolManagerAddress = makeAddr("poolManagerAddress");
        bittyVault.initialize(
            address(this),
            address(mockWETH),
            poolManagerAddress,
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_InitErrorWithAlreadyInitialized() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(1),
            address(mockWETH),
            poolManagerAddress,
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        vm.expectRevert();
        newVault.initialize(
            address(1),
            address(mockWETH),
            poolManagerAddress,
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_SetTrustToIrrevocable() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            address(mockWETH),
            poolManagerAddress,
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        newVault.setToIrrevocable();
        assertEq(newVault.revocable(), false);
    }

    function test_RevocableAfterPing() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            address(mockWETH),
            poolManagerAddress,
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        newVault.setAutoIrrevocableAfterNoPing(2);
        newVault.ping();
        vm.warp(block.timestamp + 1);
        assertEq(newVault.revocable(), true);
    }

    function test_AutoIrrevocableAfterNoPing() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(address(this), address(1), migratorAddress);
        newVault.setAutoIrrevocableAfterNoPing(1);
        vm.warp(block.timestamp + 2);
        assertEq(newVault.revocable(), false);
    }

    function test_ChangeGrantorAddressErrorWithNotRevocable() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(address(this), address(1), migratorAddress);
        newVault.setToIrrevocable();
        vm.expectRevert("Only revocable");
        newVault.changeGrantorAddress(address(1));
    }

    function test_ChangeGrantorAddressErrorWithAddressZero() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(address(this), address(1), migratorAddress);
        vm.expectRevert(AddressZero.selector);
        newVault.changeGrantorAddress(address(0));
    }

    function test_OnlyTrusteeOrGrantor_GrantorCanCallWhenNoTrustee() public {
        address newAsset = makeAddr("newAsset");
        address[] memory assets = new address[](1);
        assets[0] = newAsset;

        vm.startPrank(tx.origin);
        address[] memory assetArray = new address[](1);
        assetArray[0] = newAsset;
        IWhiteList(whiteListAddress).addAssets(assetArray);
        vm.stopPrank();

        bittyVault.addAssets(assets);
        assertTrue(bittyVault.getAssets().length > 0, "Asset should be added");
    }

    function test_OnlyTrusteeOrGrantor_UnauthorizedCannotCallWhenNoTrustee() public {
        address unauthorized = makeAddr("unauthorized");
        address newAsset = makeAddr("newAsset");
        address[] memory assets = new address[](1);
        assets[0] = newAsset;

        vm.startPrank(tx.origin);
        address[] memory assetArray = new address[](1);
        assetArray[0] = newAsset;
        IWhiteList(whiteListAddress).addAssets(assetArray);
        vm.stopPrank();

        vm.prank(unauthorized);
        vm.expectRevert("Only grantor");
        bittyVault.addAssets(assets);
    }

    function test_OnlyTrusteeOrGrantor_GrantorCanCallSetRebalanceRulesWhenNoTrustee() public {
        IAssetManager.RebalanceLimit memory rebalanceLimit = IAssetManager.RebalanceLimit({
            minimalStableCoinBalance: 100 * 1e6, minimalTimestampBetweenRebalances: 30, maxRebalancePercentage: 10
        });

        bittyVault.setRebalanceRules(rebalanceLimit);
    }

    function test_OnlyTrusteeOrGrantor_UnauthorizedCannotCallSetRebalanceRulesWhenNoTrustee() public {
        address unauthorized = makeAddr("unauthorized");
        IAssetManager.RebalanceLimit memory rebalanceLimit = IAssetManager.RebalanceLimit({
            minimalStableCoinBalance: 100 * 1e6, minimalTimestampBetweenRebalances: 30, maxRebalancePercentage: 10
        });

        vm.prank(unauthorized);
        vm.expectRevert("Only grantor");
        bittyVault.setRebalanceRules(rebalanceLimit);
    }

    function test_OnlyTrusteeOrGrantor_GrantorCanCallRemoveAssetsWhenNoTrustee() public {
        address newAsset = makeAddr("newAsset");
        address[] memory assets = new address[](1);
        assets[0] = newAsset;

        vm.startPrank(tx.origin);
        address[] memory assetArray = new address[](1);
        assetArray[0] = newAsset;
        IWhiteList(whiteListAddress).addAssets(assetArray);
        vm.stopPrank();

        bittyVault.addAssets(assets);

        bittyVault.removeAssets(assets);
        assertEq(bittyVault.getAssets().length, 0, "Asset should be removed");
    }

    function test_OnlyTrusteeOrGrantor_GrantorCanCallAddStableCoinsWhenNoTrustee() public {
        address newStableCoin = makeAddr("newStableCoin");
        address[] memory stableCoins = new address[](1);
        stableCoins[0] = newStableCoin;

        vm.startPrank(tx.origin);
        address[] memory stableCoinArray = new address[](1);
        stableCoinArray[0] = newStableCoin;
        IWhiteList(whiteListAddress).addStableCoins(stableCoinArray);
        vm.stopPrank();

        bittyVault.addStableCoins(stableCoins);
        assertTrue(bittyVault.getStableCoins().length > 0, "StableCoin should be added");
    }

    function test_OnlyTrusteeOrGrantor_GrantorCanCallAddYieldProvidersWhenNoTrustee() public {
        address newYieldProvider = makeAddr("newYieldProvider");
        address[] memory yieldProviders = new address[](1);
        yieldProviders[0] = newYieldProvider;

        vm.startPrank(tx.origin);
        address[] memory yieldProviderArray = new address[](1);
        yieldProviderArray[0] = newYieldProvider;
        IWhiteList(whiteListAddress).addYieldProviders(yieldProviderArray);
        vm.stopPrank();

        bittyVault.addYieldProviders(yieldProviders);
        assertTrue(bittyVault.getYieldProviders().length > 0, "YieldProvider should be added");
    }

    function test_OnlyTrusteeOrGrantor_GrantorCanCallAddSwapProvidersWhenNoTrustee() public {
        address newSwapProvider = makeAddr("newSwapProvider");
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = newSwapProvider;

        vm.startPrank(tx.origin);
        address[] memory swapProviderArray = new address[](1);
        swapProviderArray[0] = newSwapProvider;
        IWhiteList(whiteListAddress).addSwapProviders(swapProviderArray);
        vm.stopPrank();

        bittyVault.addSwapProviders(swapProviders);
        assertTrue(bittyVault.getSwapProviders().length > 0, "SwapProvider should be added");
    }

    function test_OnlyTrusteeOrGrantor_TrusteeCanCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address newAsset = makeAddr("newAsset");
        address[] memory assets = new address[](1);
        assets[0] = newAsset;

        vm.startPrank(tx.origin);
        address[] memory assetArray = new address[](1);
        assetArray[0] = newAsset;
        IWhiteList(whiteListAddress).addAssets(assetArray);
        vm.stopPrank();

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        bittyVault.addAssets(assets);
        assertTrue(bittyVault.getAssets().length > 0, "Asset should be added by trustee");
    }

    function test_OnlyTrusteeOrGrantor_GrantorCannotCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address newAsset = makeAddr("newAsset");
        address[] memory assets = new address[](1);
        assets[0] = newAsset;

        vm.startPrank(tx.origin);
        address[] memory assetArray = new address[](1);
        assetArray[0] = newAsset;
        IWhiteList(whiteListAddress).addAssets(assetArray);
        vm.stopPrank();

        bittyVault.setTrustee(trustee);

        vm.expectRevert("Only trustee");
        bittyVault.addAssets(assets);
    }

    function test_OnlyTrusteeOrGrantor_UnauthorizedCannotCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address unauthorized = makeAddr("unauthorized");
        address newAsset = makeAddr("newAsset");
        address[] memory assets = new address[](1);
        assets[0] = newAsset;

        vm.startPrank(tx.origin);
        address[] memory assetArray = new address[](1);
        assetArray[0] = newAsset;
        IWhiteList(whiteListAddress).addAssets(assetArray);
        vm.stopPrank();

        bittyVault.setTrustee(trustee);

        vm.prank(unauthorized);
        vm.expectRevert("Only trustee");
        bittyVault.addAssets(assets);
    }

    function test_OnlyTrusteeOrGrantor_TrusteeCanCallSetRebalanceRulesWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        IAssetManager.RebalanceLimit memory rebalanceLimit = IAssetManager.RebalanceLimit({
            minimalStableCoinBalance: 100 * 1e6, minimalTimestampBetweenRebalances: 30, maxRebalancePercentage: 10
        });

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        bittyVault.setRebalanceRules(rebalanceLimit);
    }

    function test_OnlyTrusteeOrGrantor_GrantorCannotCallSetRebalanceRulesWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        IAssetManager.RebalanceLimit memory rebalanceLimit = IAssetManager.RebalanceLimit({
            minimalStableCoinBalance: 100 * 1e6, minimalTimestampBetweenRebalances: 30, maxRebalancePercentage: 10
        });

        bittyVault.setTrustee(trustee);

        vm.expectRevert("Only trustee");
        bittyVault.setRebalanceRules(rebalanceLimit);
    }

    function test_OnlyTrusteeOrGrantor_TrusteeCanCallSetAssetConfigWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        MockERC20 mockToken = new MockERC20("Token", "TKN", 18);
        address assetAddress = address(mockToken);
        IAssetManager.AssetConfig memory assetConfig =
            IAssetManager.AssetConfig({minimalBalance: 100 * 1e18, minimalDurationBetweenRebalances: 30});

        vm.startPrank(tx.origin);
        address[] memory assetArray = new address[](1);
        assetArray[0] = assetAddress;
        IWhiteList(whiteListAddress).addAssets(assetArray);
        vm.stopPrank();

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        address[] memory assets = new address[](1);
        assets[0] = assetAddress;
        bittyVault.addAssets(assets);

        vm.prank(trustee);
        bittyVault.setAssetConfig(assetAddress, assetConfig);
    }

    function test_OnlyTrusteeOrGrantor_GrantorCannotCallSetAssetConfigWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        MockERC20 mockToken = new MockERC20("Token", "TKN", 18);
        address assetAddress = address(mockToken);
        IAssetManager.AssetConfig memory assetConfig =
            IAssetManager.AssetConfig({minimalBalance: 100 * 1e18, minimalDurationBetweenRebalances: 30});

        vm.startPrank(tx.origin);
        address[] memory assetArray = new address[](1);
        assetArray[0] = assetAddress;
        IWhiteList(whiteListAddress).addAssets(assetArray);
        vm.stopPrank();

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        address[] memory assets = new address[](1);
        assets[0] = assetAddress;
        bittyVault.addAssets(assets);

        vm.expectRevert("Only trustee");
        bittyVault.setAssetConfig(assetAddress, assetConfig);
    }

    function test_InitializeWithBytesMemoryReverts() public {
        BittyVault newVault = new BittyVault();
        bytes memory args = abi.encode("test");
        vm.expectRevert(AlreadyInitialized.selector);
        newVault.initialize(address(1), args);
    }

    function test_SetStartDistributionTimestampRevertsIfAlreadySet() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            address(mockWETH),
            poolManagerAddress,
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );

        uint256 timestamp = block.timestamp + 1 days;
        newVault.setStartDistributionTimestamp(timestamp);

        vm.expectRevert(StartDistributionTimestampAlreadySet.selector);
        newVault.setStartDistributionTimestamp(timestamp + 1 days);
    }

    function test_CreateAndMigrate_GrantorCanCallWhenNoTrustee() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            address(mockWETH),
            poolManagerAddress,
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );

        Migrator migrator = Migrator(migratorAddress);
        MockVault mockVaultImpl = new MockVault(2);
        vm.prank(address(this));
        migrator.setVersionizedVault(address(mockVaultImpl), abi.encode(uint256(2)), false);

        address nextVault = newVault.createAndMigrate(2, "salt");
        assertTrue(nextVault != address(0), "Should return next vault address");
    }

    function test_MigrateAssets_GrantorCanCallWhenNoTrustee() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            address(mockWETH),
            poolManagerAddress,
            whiteListAddress,
            migratorAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );

        Migrator migrator = Migrator(migratorAddress);
        MockVault mockVaultImpl = new MockVault(2);
        vm.prank(address(this));
        migrator.setVersionizedVault(address(mockVaultImpl), abi.encode(uint256(2)), false);

        address createdVault = newVault.createAndMigrate(2, "salt");
        assertTrue(createdVault != address(0), "Vault should be created");

        newVault.migrateAssets(2);
    }

    function test_RemoveStableCoins_GrantorCanCallWhenNoTrustee() public {
        address stableCoin1 = makeAddr("stableCoin1");
        address stableCoin2 = makeAddr("stableCoin2");
        address[] memory stableCoins = new address[](2);
        stableCoins[0] = stableCoin1;
        stableCoins[1] = stableCoin2;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addStableCoins(stableCoins);
        vm.stopPrank();

        bittyVault.addStableCoins(stableCoins);
        assertEq(bittyVault.getStableCoins().length, 2, "Should have 2 stablecoins");

        bittyVault.removeStableCoins(stableCoins);
        assertEq(bittyVault.getStableCoins().length, 0, "Should have 0 stablecoins after removal");
    }

    function test_RemoveStableCoins_RemoveSingleStableCoin() public {
        address stableCoin1 = makeAddr("stableCoin1");
        address stableCoin2 = makeAddr("stableCoin2");
        address[] memory stableCoins = new address[](2);
        stableCoins[0] = stableCoin1;
        stableCoins[1] = stableCoin2;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addStableCoins(stableCoins);
        vm.stopPrank();

        bittyVault.addStableCoins(stableCoins);
        assertEq(bittyVault.getStableCoins().length, 2, "Should have 2 stablecoins");

        address[] memory toRemove = new address[](1);
        toRemove[0] = stableCoin1;
        bittyVault.removeStableCoins(toRemove);
        assertEq(bittyVault.getStableCoins().length, 1, "Should have 1 stablecoin after removal");
    }

    function test_RemoveStableCoins_RemoveNonExistentStableCoin() public {
        address stableCoin1 = makeAddr("stableCoin1");
        address[] memory stableCoins = new address[](1);
        stableCoins[0] = stableCoin1;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addStableCoins(stableCoins);
        vm.stopPrank();

        bittyVault.removeStableCoins(stableCoins);
        assertEq(bittyVault.getStableCoins().length, 0, "Should still have 0 stablecoins");
    }

    function test_RemoveStableCoins_EmptyArray() public {
        address[] memory emptyArray = new address[](0);
        bittyVault.removeStableCoins(emptyArray);
        assertEq(bittyVault.getStableCoins().length, 0, "Should still have 0 stablecoins");
    }

    function test_RemoveStableCoins_TrusteeCanCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address stableCoin1 = makeAddr("stableCoin1");
        address[] memory stableCoins = new address[](1);
        stableCoins[0] = stableCoin1;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addStableCoins(stableCoins);
        vm.stopPrank();

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        bittyVault.addStableCoins(stableCoins);
        assertEq(bittyVault.getStableCoins().length, 1, "Should have 1 stablecoin");

        vm.prank(trustee);
        bittyVault.removeStableCoins(stableCoins);
        assertEq(bittyVault.getStableCoins().length, 0, "Should have 0 stablecoins after removal");
    }

    function test_RemoveStableCoins_GrantorCannotCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address stableCoin1 = makeAddr("stableCoin1");
        address[] memory stableCoins = new address[](1);
        stableCoins[0] = stableCoin1;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addStableCoins(stableCoins);
        vm.stopPrank();

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        bittyVault.addStableCoins(stableCoins);

        vm.expectRevert("Only trustee");
        bittyVault.removeStableCoins(stableCoins);
    }

    function test_RemoveSwapProviders_GrantorCanCallWhenNoTrustee() public {
        address swapProvider1 = makeAddr("swapProvider1");
        address swapProvider2 = makeAddr("swapProvider2");
        address[] memory swapProviders = new address[](2);
        swapProviders[0] = swapProvider1;
        swapProviders[1] = swapProvider2;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);
        vm.stopPrank();

        bittyVault.addSwapProviders(swapProviders);
        assertEq(bittyVault.getSwapProviders().length, 2, "Should have 2 swap providers");

        bittyVault.removeSwapProviders(swapProviders);
        assertEq(bittyVault.getSwapProviders().length, 0, "Should have 0 swap providers after removal");
    }

    function test_RemoveSwapProviders_RemoveSingleSwapProvider() public {
        address swapProvider1 = makeAddr("swapProvider1");
        address swapProvider2 = makeAddr("swapProvider2");
        address[] memory swapProviders = new address[](2);
        swapProviders[0] = swapProvider1;
        swapProviders[1] = swapProvider2;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);
        vm.stopPrank();

        bittyVault.addSwapProviders(swapProviders);
        assertEq(bittyVault.getSwapProviders().length, 2, "Should have 2 swap providers");

        address[] memory toRemove = new address[](1);
        toRemove[0] = swapProvider1;
        bittyVault.removeSwapProviders(toRemove);
        assertEq(bittyVault.getSwapProviders().length, 1, "Should have 1 swap provider after removal");
    }

    function test_RemoveSwapProviders_RemoveNonExistentSwapProvider() public {
        address swapProvider1 = makeAddr("swapProvider1");
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = swapProvider1;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);
        vm.stopPrank();

        bittyVault.removeSwapProviders(swapProviders);
        assertEq(bittyVault.getSwapProviders().length, 0, "Should still have 0 swap providers");
    }

    function test_RemoveSwapProviders_EmptyArray() public {
        address[] memory emptyArray = new address[](0);
        bittyVault.removeSwapProviders(emptyArray);
        assertEq(bittyVault.getSwapProviders().length, 0, "Should still have 0 swap providers");
    }

    function test_RemoveSwapProviders_TrusteeCanCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address swapProvider1 = makeAddr("swapProvider1");
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = swapProvider1;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);
        vm.stopPrank();

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        bittyVault.addSwapProviders(swapProviders);
        assertEq(bittyVault.getSwapProviders().length, 1, "Should have 1 swap provider");

        vm.prank(trustee);
        bittyVault.removeSwapProviders(swapProviders);
        assertEq(bittyVault.getSwapProviders().length, 0, "Should have 0 swap providers after removal");
    }

    function test_RemoveSwapProviders_GrantorCannotCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address swapProvider1 = makeAddr("swapProvider1");
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = swapProvider1;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);
        vm.stopPrank();

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        bittyVault.addSwapProviders(swapProviders);

        vm.expectRevert("Only trustee");
        bittyVault.removeSwapProviders(swapProviders);
    }

    function test_RemoveSwapProviders_UnauthorizedCannotCallWhenNoTrustee() public {
        address unauthorized = makeAddr("unauthorized");
        address swapProvider1 = makeAddr("swapProvider1");
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = swapProvider1;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);
        vm.stopPrank();

        bittyVault.addSwapProviders(swapProviders);

        vm.prank(unauthorized);
        vm.expectRevert("Only grantor");
        bittyVault.removeSwapProviders(swapProviders);
    }

    function test_RemoveStableCoins_UnauthorizedCannotCallWhenNoTrustee() public {
        address unauthorized = makeAddr("unauthorized");
        address stableCoin1 = makeAddr("stableCoin1");
        address[] memory stableCoins = new address[](1);
        stableCoins[0] = stableCoin1;

        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addStableCoins(stableCoins);
        vm.stopPrank();

        bittyVault.addStableCoins(stableCoins);

        vm.prank(unauthorized);
        vm.expectRevert("Only grantor");
        bittyVault.removeStableCoins(stableCoins);
    }
}
