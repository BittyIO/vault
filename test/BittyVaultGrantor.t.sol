// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {
    AddressZero,
    NotWhiteListed,
    AlreadyInitialized,
    StartDistributionTimestampAlreadySet,
    TimestampIsZero,
    TimestampNotFound,
    NotAuthorized,
    OnlyGrantor,
    OnlyTrustee,
    OnlyRevocable,
    AutoIrrevocableAfterNoPingNotSet
} from "../src/interfaces/Errors.sol";
import {IBeneficiary} from "../src/interfaces/IBeneficiary.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {Migrator} from "../src/Migrator.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";
import {IWhiteList} from "../src/interfaces/IWhiteList.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {MockVault} from "./mock/MockVault.sol";
import {InsufficientBalance} from "../src/interfaces/Errors.sol";
import {OnlyBeneficiary} from "../src/BittyVault.sol";

// Mock ERC20 token that can fail transfers for testing
contract MockERC20FailingTransfer is MockERC20 {
    bool public shouldFailTransfer;

    constructor(string memory name, string memory symbol, uint8 decimals) MockERC20(name, symbol, decimals) {}

    function setShouldFailTransfer(bool _shouldFail) external {
        shouldFailTransfer = _shouldFail;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (shouldFailTransfer) {
            return false;
        }
        return super.transfer(to, amount);
    }
}

contract BittyVaultGrantorTest is Test {
    BittyVault public bittyVault;
    WETH public mockWETH;
    address public whiteListAddress;
    address public migratorAddress;

    receive() external payable {}

    function setUp() public {
        mockWETH = new WETH();
        bittyVault = new BittyVault();
        WhiteList whiteList = new WhiteList();
        whiteListAddress = address(whiteList);
        migratorAddress = address(new Migrator());
        bittyVault.initialize(
            address(this),
            address(whiteList),
            address(migratorAddress),
            address(mockWETH),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_InitErrorWithAlreadyInitialized() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        vm.expectRevert();
        newVault.initialize(
            address(this),
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
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
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
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
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        newVault.setAutoIrrevocableAfterNoPing(2);
        newVault.grantorPing();
        vm.warp(block.timestamp + 1);
        assertEq(newVault.revocable(), true);
    }

    function test_AutoIrrevocableAfterNoPing() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        newVault.setAutoIrrevocableAfterNoPing(1);
        vm.warp(block.timestamp + 2);
        assertEq(newVault.revocable(), false);
    }

    function test_SetAutoIrrevocableAfterNoPing_RevertsIfNotRevocable() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        newVault.setToIrrevocable();
        vm.expectRevert(OnlyRevocable.selector);
        newVault.setAutoIrrevocableAfterNoPing(1);
    }

    function test_SetAutoIrrevocableAfterNoPing_RevertsIfAutoIrrevocableExpired() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        newVault.setAutoIrrevocableAfterNoPing(1);
        vm.warp(block.timestamp + 2);
        assertEq(newVault.revocable(), false);
        vm.expectRevert(OnlyRevocable.selector);
        newVault.setAutoIrrevocableAfterNoPing(1);
    }

    function test_ChangeGrantorAddressErrorWithNotRevocable() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        newVault.setToIrrevocable();
        vm.expectRevert(OnlyRevocable.selector);
        newVault.changeGrantorAddress(address(1));
    }

    function test_ChangeGrantorAddressErrorWithAddressZero() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        vm.expectRevert(AddressZero.selector);
        newVault.changeGrantorAddress(address(0));
    }

    function test_OnlyTrusteeOrGrantor_GrantorCanCallWhenNoTrustee() public {
        address newAsset = makeAddr("newAsset");
        address[] memory assets = new address[](1);
        assets[0] = newAsset;

        address[] memory assetArray = new address[](1);
        assetArray[0] = newAsset;
        IWhiteList(whiteListAddress).addAssets(assetArray);

        bittyVault.addAssets(assets);
        assertTrue(bittyVault.getAssets().length > 0, "Asset should be added");
    }

    function test_OnlyTrusteeOrGrantor_UnauthorizedCannotCallWhenNoTrustee() public {
        address unauthorized = makeAddr("unauthorized");
        address newAsset = makeAddr("newAsset");
        address[] memory assets = new address[](1);
        assets[0] = newAsset;

        address[] memory assetArray = new address[](1);
        assetArray[0] = newAsset;
        IWhiteList(whiteListAddress).addAssets(assetArray);

        vm.prank(unauthorized);
        vm.expectRevert(OnlyGrantor.selector);
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
        vm.expectRevert(OnlyGrantor.selector);
        bittyVault.setRebalanceRules(rebalanceLimit);
    }

    function test_OnlyTrusteeOrGrantor_GrantorCanCallRemoveAssetsWhenNoTrustee() public {
        address newAsset = makeAddr("newAsset");
        address[] memory assets = new address[](1);
        assets[0] = newAsset;

        address[] memory assetArray = new address[](1);
        assetArray[0] = newAsset;
        IWhiteList(whiteListAddress).addAssets(assetArray);

        bittyVault.addAssets(assets);

        bittyVault.removeAssets(assets);
        assertEq(bittyVault.getAssets().length, 0, "Asset should be removed");
    }

    function test_OnlyTrusteeOrGrantor_GrantorCanCallAddStableCoinsWhenNoTrustee() public {
        address newStableCoin = makeAddr("newStableCoin");
        address[] memory stableCoins = new address[](1);
        stableCoins[0] = newStableCoin;

        address[] memory stableCoinArray = new address[](1);
        stableCoinArray[0] = newStableCoin;
        IWhiteList(whiteListAddress).addStableCoins(stableCoinArray);

        bittyVault.addStableCoins(stableCoins);
        assertTrue(bittyVault.getStableCoins().length > 0, "StableCoin should be added");
    }

    function test_OnlyTrusteeOrGrantor_GrantorCanCallAddYieldProvidersWhenNoTrustee() public {
        address newYieldProvider = makeAddr("newYieldProvider");
        address[] memory yieldProviders = new address[](1);
        yieldProviders[0] = newYieldProvider;

        address[] memory yieldProviderArray = new address[](1);
        yieldProviderArray[0] = newYieldProvider;
        IWhiteList(whiteListAddress).addYieldProviders(yieldProviderArray);

        bittyVault.addYieldProviders(yieldProviders);
        assertTrue(bittyVault.getYieldProviders().length > 0, "YieldProvider should be added");
    }

    function test_OnlyTrusteeOrGrantor_GrantorCanCallAddSwapProvidersWhenNoTrustee() public {
        address newSwapProvider = makeAddr("newSwapProvider");
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = newSwapProvider;

        address[] memory swapProviderArray = new address[](1);
        swapProviderArray[0] = newSwapProvider;
        IWhiteList(whiteListAddress).addSwapProviders(swapProviderArray);

        bittyVault.addSwapProviders(swapProviders);
        assertTrue(bittyVault.getSwapProviders().length > 0, "SwapProvider should be added");
    }

    function test_OnlyTrusteeOrGrantor_TrusteeCanCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address newAsset = makeAddr("newAsset");
        address[] memory assets = new address[](1);
        assets[0] = newAsset;

        address[] memory assetArray = new address[](1);
        assetArray[0] = newAsset;
        IWhiteList(whiteListAddress).addAssets(assetArray);

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

        address[] memory assetArray = new address[](1);
        assetArray[0] = newAsset;
        IWhiteList(whiteListAddress).addAssets(assetArray);

        bittyVault.setTrustee(trustee);

        vm.expectRevert(OnlyTrustee.selector);
        bittyVault.addAssets(assets);
    }

    function test_OnlyTrusteeOrGrantor_UnauthorizedCannotCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address unauthorized = makeAddr("unauthorized");
        address newAsset = makeAddr("newAsset");
        address[] memory assets = new address[](1);
        assets[0] = newAsset;

        address[] memory assetArray = new address[](1);
        assetArray[0] = newAsset;
        IWhiteList(whiteListAddress).addAssets(assetArray);

        bittyVault.setTrustee(trustee);

        vm.prank(unauthorized);
        vm.expectRevert(OnlyTrustee.selector);
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

        vm.expectRevert(OnlyTrustee.selector);
        bittyVault.setRebalanceRules(rebalanceLimit);
    }

    function test_OnlyTrusteeOrGrantor_TrusteeCanCallSetAssetConfigWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        MockERC20 mockToken = new MockERC20("Token", "TKN", 18);
        address assetAddress = address(mockToken);
        IAssetManager.AssetConfig memory assetConfig =
            IAssetManager.AssetConfig({minimalBalance: 100 * 1e18, minimalDurationBetweenRebalances: 30});

        address[] memory assetArray = new address[](1);
        assetArray[0] = assetAddress;
        IWhiteList(whiteListAddress).addAssets(assetArray);

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

        address[] memory assetArray = new address[](1);
        assetArray[0] = assetAddress;
        IWhiteList(whiteListAddress).addAssets(assetArray);

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        address[] memory assets = new address[](1);
        assets[0] = assetAddress;
        bittyVault.addAssets(assets);

        vm.expectRevert(OnlyTrustee.selector);
        bittyVault.setAssetConfig(assetAddress, assetConfig);
    }

    function test_InitializeWithBytesMemoryReverts() public {
        BittyVault newVault = new BittyVault();
        bytes memory args = abi.encode("test");
        vm.expectRevert(AlreadyInitialized.selector);
        newVault.initializeFromPreviousVersion(address(1), args);
    }

    function test_SetStartDistributionTimestampRevertsIfAlreadySet() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
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
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
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
            whiteListAddress,
            migratorAddress,
            address(mockWETH),
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

        IWhiteList(whiteListAddress).addStableCoins(stableCoins);

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

        IWhiteList(whiteListAddress).addStableCoins(stableCoins);

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

        IWhiteList(whiteListAddress).addStableCoins(stableCoins);

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

        IWhiteList(whiteListAddress).addStableCoins(stableCoins);

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

        IWhiteList(whiteListAddress).addStableCoins(stableCoins);

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        bittyVault.addStableCoins(stableCoins);

        vm.expectRevert(OnlyTrustee.selector);
        bittyVault.removeStableCoins(stableCoins);
    }

    function test_RemoveSwapProviders_GrantorCanCallWhenNoTrustee() public {
        address swapProvider1 = makeAddr("swapProvider1");
        address swapProvider2 = makeAddr("swapProvider2");
        address[] memory swapProviders = new address[](2);
        swapProviders[0] = swapProvider1;
        swapProviders[1] = swapProvider2;

        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);

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

        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);

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

        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);

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

        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);

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

        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        bittyVault.addSwapProviders(swapProviders);

        vm.expectRevert(OnlyTrustee.selector);
        bittyVault.removeSwapProviders(swapProviders);
    }

    function test_RemoveSwapProviders_UnauthorizedCannotCallWhenNoTrustee() public {
        address unauthorized = makeAddr("unauthorized");
        address swapProvider1 = makeAddr("swapProvider1");
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = swapProvider1;

        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);

        bittyVault.addSwapProviders(swapProviders);

        vm.prank(unauthorized);
        vm.expectRevert(OnlyGrantor.selector);
        bittyVault.removeSwapProviders(swapProviders);
    }

    function test_RemoveStableCoins_UnauthorizedCannotCallWhenNoTrustee() public {
        address unauthorized = makeAddr("unauthorized");
        address stableCoin1 = makeAddr("stableCoin1");
        address[] memory stableCoins = new address[](1);
        stableCoins[0] = stableCoin1;

        IWhiteList(whiteListAddress).addStableCoins(stableCoins);

        bittyVault.addStableCoins(stableCoins);

        vm.prank(unauthorized);
        vm.expectRevert(OnlyGrantor.selector);
        bittyVault.removeStableCoins(stableCoins);
    }

    function test_Revoke_TransfersETHToGrantor() public {
        address grantor = address(this);
        vm.deal(address(bittyVault), 1 ether);
        uint256 grantorETHBefore = grantor.balance;
        uint256 vaultETHBefore = address(bittyVault).balance;
        assertEq(vaultETHBefore, 1 ether);
        bittyVault.revoke();
        assertGt(grantor.balance, grantorETHBefore);
        assertEq(address(bittyVault).balance, 0);
    }

    function test_Revoke_TransfersERC20ToGrantor() public {
        MockERC20 mockUSDT = new MockERC20("USDT", "USDT", 6);
        address grantor = address(this);
        address[] memory stableCoins = new address[](1);
        stableCoins[0] = address(mockUSDT);

        IWhiteList(whiteListAddress).addStableCoins(stableCoins);

        bittyVault.addStableCoins(stableCoins);

        uint256 usdtAmount = 1000 * 10 ** mockUSDT.decimals();
        deal(address(mockUSDT), address(bittyVault), usdtAmount);

        uint256 grantorUSDTBefore = mockUSDT.balanceOf(grantor);
        bittyVault.revoke();
        assertEq(mockUSDT.balanceOf(grantor), grantorUSDTBefore + usdtAmount);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0);
    }

    function test_Revoke_RevertsIfNotRevocable() public {
        bittyVault.setToIrrevocable();
        vm.expectRevert(OnlyRevocable.selector);
        bittyVault.revoke();
    }

    function test_Revoke_RevertsIfNotGrantor() public {
        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(OnlyGrantor.selector);
        bittyVault.revoke();
    }

    function test_ChangeGrantorAddress_SameAddressDoesNothing() public {
        address currentGrantor = address(this);
        uint256 balanceBefore = address(bittyVault).balance;
        bittyVault.changeGrantorAddress(currentGrantor);
        assertEq(bittyVault.grantor(), currentGrantor);
        assertEq(address(bittyVault).balance, balanceBefore);
    }

    function test_ChangeGrantorAddress_Success() public {
        address newGrantor = makeAddr("newGrantor");
        bittyVault.changeGrantorAddress(newGrantor);
        assertEq(bittyVault.grantor(), newGrantor);
    }

    function test_Upgrade_RevertsIfAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        bittyVault.upgrade(address(0));
    }

    function test_Upgrade_Success() public {
        address upgradeToContract = makeAddr("upgradeToContract");
        bittyVault.upgrade(upgradeToContract);
    }

    function test_Upgrade_RevertsIfNotGrantor() public {
        address unauthorized = makeAddr("unauthorized");
        address upgradeToContract = makeAddr("upgradeToContract");
        vm.prank(unauthorized);
        vm.expectRevert(OnlyGrantor.selector);
        bittyVault.upgrade(upgradeToContract);
    }

    function test_DistributionStarted_BeforeTimestamp() public {
        uint256 futureTimestamp = block.timestamp + 100 days;
        bittyVault.setStartDistributionTimestamp(futureTimestamp);
        assertFalse(bittyVault.distributionStarted());
    }

    function test_DistributionStarted_AfterTimestamp() public {
        uint256 pastTimestamp = block.timestamp;
        bittyVault.setStartDistributionTimestamp(pastTimestamp);
        assertTrue(bittyVault.distributionStarted());
    }

    function test_DistributionStarted_AtTimestamp() public {
        uint256 currentTimestamp = block.timestamp;
        bittyVault.setStartDistributionTimestamp(currentTimestamp);
        assertTrue(bittyVault.distributionStarted());
    }

    function test_Revocable_WhenIrrevocableSet() public {
        bittyVault.setToIrrevocable();
        assertFalse(bittyVault.revocable());
    }

    function test_Revocable_WhenAutoIrrevocableNotSet() public view {
        assertTrue(bittyVault.revocable());
    }

    function test_Revocable_WhenAutoIrrevocableSetAndNotExpired() public {
        bittyVault.setAutoIrrevocableAfterNoPing(100 days);
        assertTrue(bittyVault.revocable());
    }

    function test_Revocable_WhenAutoIrrevocableSetAndExpired() public {
        bittyVault.setAutoIrrevocableAfterNoPing(1 days);
        vm.warp(block.timestamp + 2 days);
        assertFalse(bittyVault.revocable());
    }

    function test_Revocable_WhenAutoIrrevocableSetAndPinged() public {
        bittyVault.setAutoIrrevocableAfterNoPing(1 days);
        bittyVault.grantorPing();
        vm.warp(block.timestamp + 12 hours);
        assertTrue(bittyVault.revocable());
    }

    function test_Revocable_WhenAutoIrrevocableSetAndPingedThenExpired() public {
        bittyVault.setAutoIrrevocableAfterNoPing(1 days);
        bittyVault.grantorPing();
        vm.warp(block.timestamp + 2 days);
        assertFalse(bittyVault.revocable());
    }

    function test_GetAllTriggerEventKeys_Empty() public view {
        bytes32[] memory keys = bittyVault.getAllTriggerEventKeys();
        assertEq(keys.length, 0);
    }

    function test_GetAllTriggerEventKeys_WithEvents() public {
        string[] memory eventNames = new string[](2);
        eventNames[0] = "Marriage";
        eventNames[1] = "Graduation";
        IBeneficiary.TriggerEvent[] memory triggerEvents = new IBeneficiary.TriggerEvent[](2);
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: makeAddr("trigger1"), amount: 1000, isPercentage: false});
        triggerEvents[1] =
            IBeneficiary.TriggerEvent({triggerAddress: makeAddr("trigger2"), amount: 2000, isPercentage: false});

        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        bytes32[] memory keys = bittyVault.getAllTriggerEventKeys();
        assertEq(keys.length, 2);
    }

    function test_GetAllTimeEventKeys_Empty() public view {
        uint256[] memory keys = bittyVault.getAllTimeEventKeys();
        assertEq(keys.length, 0);
    }

    function test_GetAllTimeEventKeys_WithEvents() public {
        uint256[] memory timestamps = new uint256[](2);
        timestamps[0] = block.timestamp + 1 days;
        timestamps[1] = block.timestamp + 2 days;
        IBeneficiary.TimeEvent[] memory timeEvents = new IBeneficiary.TimeEvent[](2);
        timeEvents[0] = IBeneficiary.TimeEvent({amount: 1000, isPercentage: false});
        timeEvents[1] = IBeneficiary.TimeEvent({amount: 2000, isPercentage: false});

        bittyVault.addTimeEvents(timestamps, timeEvents);
        uint256[] memory keys = bittyVault.getAllTimeEventKeys();
        assertEq(keys.length, 2);
    }

    function test_RemoveTimeEvents_Success() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = block.timestamp + 1 days;
        IBeneficiary.TimeEvent[] memory timeEvents = new IBeneficiary.TimeEvent[](1);
        timeEvents[0] = IBeneficiary.TimeEvent({amount: 1000, isPercentage: false});

        bittyVault.addTimeEvents(timestamps, timeEvents);
        assertEq(bittyVault.getAllTimeEventKeys().length, 1);

        bittyVault.removeTimeEvents(timestamps);
        assertEq(bittyVault.getAllTimeEventKeys().length, 0);
    }

    function test_RemoveTimeEvents_RevertsIfTimestampZero() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = 0;

        vm.expectRevert(TimestampIsZero.selector);
        bittyVault.removeTimeEvents(timestamps);
    }

    function test_RemoveTimeEvents_RevertsIfTimestampNotFound() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = block.timestamp + 1 days;

        vm.expectRevert(TimestampNotFound.selector);
        bittyVault.removeTimeEvents(timestamps);
    }

    function test_RemoveTimeEvents_RevertsIfIrrevocable() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = block.timestamp + 1 days;
        IBeneficiary.TimeEvent[] memory timeEvents = new IBeneficiary.TimeEvent[](1);
        timeEvents[0] = IBeneficiary.TimeEvent({amount: 1000, isPercentage: false});

        bittyVault.addTimeEvents(timestamps, timeEvents);
        bittyVault.setToIrrevocable();

        vm.expectRevert(OnlyRevocable.selector);
        bittyVault.removeTimeEvents(timestamps);
    }

    function test_TurnETHToWETH_Success() public {
        vm.deal(address(bittyVault), 1 ether);
        uint256 wethBalanceBefore = mockWETH.balanceOf(address(bittyVault));
        bittyVault.turnETHToWETH();
        assertEq(mockWETH.balanceOf(address(bittyVault)), wethBalanceBefore + 1 ether);
        assertEq(address(bittyVault).balance, 0);
    }

    function test_TurnETHToWETH_ZeroBalance() public {
        uint256 wethBalanceBefore = mockWETH.balanceOf(address(bittyVault));
        bittyVault.turnETHToWETH();
        assertEq(mockWETH.balanceOf(address(bittyVault)), wethBalanceBefore);
    }

    function test_TurnETHToWETH_RevertsIfWETHNotSet() public {
        BittyVault newVault = new BittyVault();
        vm.expectRevert(AddressZero.selector);
        newVault.initialize(
            address(this),
            address(0),
            migratorAddress,
            address(0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_Withdraw_Success() public {
        MockERC20 mockToken = new MockERC20("TestToken", "TEST", 18);
        uint256 withdrawAmount = 1000 * 10 ** mockToken.decimals();
        deal(address(mockToken), address(bittyVault), withdrawAmount);

        uint256 grantorBalanceBefore = mockToken.balanceOf(address(this));
        uint256 vaultBalanceBefore = mockToken.balanceOf(address(bittyVault));

        bittyVault.withdraw(address(mockToken), withdrawAmount);

        assertEq(mockToken.balanceOf(address(this)), grantorBalanceBefore + withdrawAmount);
        assertEq(mockToken.balanceOf(address(bittyVault)), vaultBalanceBefore - withdrawAmount);
    }

    function test_Withdraw_PartialAmount() public {
        MockERC20 mockToken = new MockERC20("TestToken", "TEST", 18);
        uint256 vaultBalance = 1000 * 10 ** mockToken.decimals();
        uint256 withdrawAmount = 500 * 10 ** mockToken.decimals();
        deal(address(mockToken), address(bittyVault), vaultBalance);

        uint256 grantorBalanceBefore = mockToken.balanceOf(address(this));
        bittyVault.withdraw(address(mockToken), withdrawAmount);

        assertEq(mockToken.balanceOf(address(this)), grantorBalanceBefore + withdrawAmount);
        assertEq(mockToken.balanceOf(address(bittyVault)), vaultBalance - withdrawAmount);
    }

    function test_Withdraw_ExactBalance() public {
        MockERC20 mockToken = new MockERC20("TestToken", "TEST", 18);
        uint256 withdrawAmount = 1000 * 10 ** mockToken.decimals();
        deal(address(mockToken), address(bittyVault), withdrawAmount);

        uint256 grantorBalanceBefore = mockToken.balanceOf(address(this));
        bittyVault.withdraw(address(mockToken), withdrawAmount);

        assertEq(mockToken.balanceOf(address(this)), grantorBalanceBefore + withdrawAmount);
        assertEq(mockToken.balanceOf(address(bittyVault)), 0);
    }

    function test_Withdraw_RevertsIfAssetAddressZero() public {
        MockERC20 mockToken = new MockERC20("TestToken", "TEST", 18);
        uint256 withdrawAmount = 1000 * 10 ** mockToken.decimals();
        deal(address(mockToken), address(bittyVault), withdrawAmount);

        vm.expectRevert(AddressZero.selector);
        bittyVault.withdraw(address(0), withdrawAmount);
    }

    function test_Withdraw_RevertsIfInsufficientBalance() public {
        MockERC20 mockToken = new MockERC20("TestToken", "TEST", 18);
        uint256 vaultBalance = 500 * 10 ** mockToken.decimals();
        uint256 withdrawAmount = 1000 * 10 ** mockToken.decimals();
        deal(address(mockToken), address(bittyVault), vaultBalance);

        vm.expectRevert(InsufficientBalance.selector);
        bittyVault.withdraw(address(mockToken), withdrawAmount);
    }

    function test_Withdraw_RevertsIfZeroBalance() public {
        MockERC20 mockToken = new MockERC20("TestToken", "TEST", 18);
        uint256 withdrawAmount = 1000 * 10 ** mockToken.decimals();

        vm.expectRevert(InsufficientBalance.selector);
        bittyVault.withdraw(address(mockToken), withdrawAmount);
    }

    function test_Withdraw_RevertsIfTransferFails() public {
        MockERC20FailingTransfer mockToken = new MockERC20FailingTransfer("TestToken", "TEST", 18);
        uint256 withdrawAmount = 1000 * 10 ** mockToken.decimals();
        deal(address(mockToken), address(bittyVault), withdrawAmount);

        mockToken.setShouldFailTransfer(true);

        vm.expectRevert("SafeERC20: ERC20 operation did not succeed");
        bittyVault.withdraw(address(mockToken), withdrawAmount);
    }

    function test_Withdraw_RevertsIfNotInitialized() public {
        BittyVault newVault = new BittyVault();
        MockERC20 mockToken = new MockERC20("TestToken", "TEST", 18);
        uint256 withdrawAmount = 1000 * 10 ** mockToken.decimals();

        vm.expectRevert(OnlyGrantor.selector);
        newVault.withdraw(address(mockToken), withdrawAmount);
    }

    function test_Withdraw_RevertsIfNotGrantor() public {
        MockERC20 mockToken = new MockERC20("TestToken", "TEST", 18);
        uint256 withdrawAmount = 1000 * 10 ** mockToken.decimals();
        deal(address(mockToken), address(bittyVault), withdrawAmount);

        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(OnlyGrantor.selector);
        bittyVault.withdraw(address(mockToken), withdrawAmount);
    }

    function test_Withdraw_WithDifferentTokenDecimals() public {
        MockERC20 mockToken6 = new MockERC20("Token6", "T6", 6);
        MockERC20 mockToken8 = new MockERC20("Token8", "T8", 8);
        MockERC20 mockToken18 = new MockERC20("Token18", "T18", 18);

        uint256 amount6 = 1000 * 10 ** mockToken6.decimals();
        uint256 amount8 = 1000 * 10 ** mockToken8.decimals();
        uint256 amount18 = 1000 * 10 ** mockToken18.decimals();

        deal(address(mockToken6), address(bittyVault), amount6);
        deal(address(mockToken8), address(bittyVault), amount8);
        deal(address(mockToken18), address(bittyVault), amount18);

        bittyVault.withdraw(address(mockToken6), amount6);
        bittyVault.withdraw(address(mockToken8), amount8);
        bittyVault.withdraw(address(mockToken18), amount18);

        assertEq(mockToken6.balanceOf(address(this)), amount6);
        assertEq(mockToken8.balanceOf(address(this)), amount8);
        assertEq(mockToken18.balanceOf(address(this)), amount18);
        assertEq(mockToken6.balanceOf(address(bittyVault)), 0);
        assertEq(mockToken8.balanceOf(address(bittyVault)), 0);
        assertEq(mockToken18.balanceOf(address(bittyVault)), 0);
    }

    function test_Withdraw_MultipleWithdrawals() public {
        MockERC20 mockToken = new MockERC20("TestToken", "TEST", 18);
        uint256 totalBalance = 3000 * 10 ** mockToken.decimals();
        deal(address(mockToken), address(bittyVault), totalBalance);

        uint256 firstWithdraw = 1000 * 10 ** mockToken.decimals();
        uint256 secondWithdraw = 1000 * 10 ** mockToken.decimals();
        uint256 thirdWithdraw = 1000 * 10 ** mockToken.decimals();

        bittyVault.withdraw(address(mockToken), firstWithdraw);
        assertEq(mockToken.balanceOf(address(bittyVault)), totalBalance - firstWithdraw);

        bittyVault.withdraw(address(mockToken), secondWithdraw);
        assertEq(mockToken.balanceOf(address(bittyVault)), totalBalance - firstWithdraw - secondWithdraw);

        bittyVault.withdraw(address(mockToken), thirdWithdraw);
        assertEq(mockToken.balanceOf(address(bittyVault)), 0);
        assertEq(mockToken.balanceOf(address(this)), totalBalance);
    }

    function test_Withdraw_RevertsIfNotRevocable() public {
        bittyVault.setToIrrevocable();
        assertFalse(bittyVault.revocable());
        vm.expectRevert(OnlyRevocable.selector);
        bittyVault.withdraw(address(mockWETH), 100);
    }

    function test_ResetAssets_Success() public {
        address asset1 = makeAddr("asset1");
        address asset2 = makeAddr("asset2");
        address[] memory initialAssets = new address[](2);
        initialAssets[0] = asset1;
        initialAssets[1] = asset2;

        IWhiteList(whiteListAddress).addAssets(initialAssets);

        bittyVault.addAssets(initialAssets);
        assertEq(bittyVault.getAssets().length, 2);

        address[] memory resetAssets = new address[](2);
        resetAssets[0] = asset1;
        resetAssets[1] = asset2;
        bittyVault.resetAssets(resetAssets);

        assertEq(bittyVault.getAssets().length, 2);
        address[] memory assets = bittyVault.getAssets();
        assertTrue(assets[0] == asset1 || assets[1] == asset1);
        assertTrue(assets[0] == asset2 || assets[1] == asset2);
    }

    function test_ResetAssets_RemoveAllAndAddNew() public {
        address asset1 = makeAddr("asset1");
        address asset2 = makeAddr("asset2");
        address asset3 = makeAddr("asset3");
        address[] memory initialAssets = new address[](2);
        initialAssets[0] = asset1;
        initialAssets[1] = asset2;

        IWhiteList(whiteListAddress).addAssets(initialAssets);
        address[] memory newAssets = new address[](1);
        newAssets[0] = asset3;
        IWhiteList(whiteListAddress).addAssets(newAssets);

        bittyVault.addAssets(initialAssets);
        assertEq(bittyVault.getAssets().length, 2);

        address[] memory resetAssets = new address[](3);
        resetAssets[0] = asset1;
        resetAssets[1] = asset2;
        resetAssets[2] = asset3;
        bittyVault.resetAssets(resetAssets);

        assertEq(bittyVault.getAssets().length, 3);
        address[] memory assets = bittyVault.getAssets();
        bool found1 = false;
        bool found2 = false;
        bool found3 = false;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == asset1) found1 = true;
            if (assets[i] == asset2) found2 = true;
            if (assets[i] == asset3) found3 = true;
        }
        assertTrue(found1 && found2 && found3);
    }

    function test_ResetAssets_EmptyArray() public {
        address asset1 = makeAddr("asset1");
        address[] memory initialAssets = new address[](1);
        initialAssets[0] = asset1;

        IWhiteList(whiteListAddress).addAssets(initialAssets);

        bittyVault.addAssets(initialAssets);
        assertEq(bittyVault.getAssets().length, 1);

        address[] memory emptyArray = new address[](0);
        bittyVault.resetAssets(emptyArray);

        assertEq(bittyVault.getAssets().length, 1);
        assertEq(bittyVault.getAssets()[0], asset1);
    }

    function test_ResetAssets_RevertsIfNotWhitelisted() public {
        address asset1 = makeAddr("asset1");
        address asset2 = makeAddr("asset2");
        address[] memory initialAssets = new address[](1);
        initialAssets[0] = asset1;

        IWhiteList(whiteListAddress).addAssets(initialAssets);

        bittyVault.addAssets(initialAssets);

        address[] memory resetAssets = new address[](2);
        resetAssets[0] = asset1;
        resetAssets[1] = asset2;

        vm.expectRevert(NotWhiteListed.selector);
        bittyVault.resetAssets(resetAssets);
    }

    function test_ResetAssets_RevertsIfNotInitialized() public {
        BittyVault newVault = new BittyVault();
        address asset1 = makeAddr("asset1");
        address[] memory resetAssets = new address[](1);
        resetAssets[0] = asset1;

        vm.expectRevert(NotAuthorized.selector);
        newVault.resetAssets(resetAssets);
    }

    function test_ResetAssets_GrantorCanCallWhenNoTrustee() public {
        address asset1 = makeAddr("asset1");
        address[] memory resetAssets = new address[](1);
        resetAssets[0] = asset1;

        IWhiteList(whiteListAddress).addAssets(resetAssets);

        bittyVault.resetAssets(resetAssets);
        assertEq(bittyVault.getAssets().length, 1);
        assertEq(bittyVault.getAssets()[0], asset1);
    }

    function test_ResetAssets_TrusteeCanCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address asset1 = makeAddr("asset1");
        address[] memory resetAssets = new address[](1);
        resetAssets[0] = asset1;

        IWhiteList(whiteListAddress).addAssets(resetAssets);

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        bittyVault.resetAssets(resetAssets);
        assertEq(bittyVault.getAssets().length, 1);
        assertEq(bittyVault.getAssets()[0], asset1);
    }

    function test_ResetAssets_GrantorCannotCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address asset1 = makeAddr("asset1");
        address[] memory resetAssets = new address[](1);
        resetAssets[0] = asset1;

        IWhiteList(whiteListAddress).addAssets(resetAssets);

        bittyVault.setTrustee(trustee);

        vm.expectRevert(OnlyTrustee.selector);
        bittyVault.resetAssets(resetAssets);
    }

    function test_ResetAssets_UnauthorizedCannotCallWhenNoTrustee() public {
        address unauthorized = makeAddr("unauthorized");
        address asset1 = makeAddr("asset1");
        address[] memory resetAssets = new address[](1);
        resetAssets[0] = asset1;

        IWhiteList(whiteListAddress).addAssets(resetAssets);

        vm.prank(unauthorized);
        vm.expectRevert(OnlyGrantor.selector);
        bittyVault.resetAssets(resetAssets);
    }

    function test_ResetAssets_MultipleAssets() public {
        address asset1 = makeAddr("asset1");
        address asset2 = makeAddr("asset2");
        address asset3 = makeAddr("asset3");
        address[] memory resetAssets = new address[](3);
        resetAssets[0] = asset1;
        resetAssets[1] = asset2;
        resetAssets[2] = asset3;

        IWhiteList(whiteListAddress).addAssets(resetAssets);

        bittyVault.resetAssets(resetAssets);
        assertEq(bittyVault.getAssets().length, 3);
    }

    function test_ResetStableCoins_Success() public {
        address stableCoin1 = makeAddr("stableCoin1");
        address stableCoin2 = makeAddr("stableCoin2");
        address[] memory initialStableCoins = new address[](2);
        initialStableCoins[0] = stableCoin1;
        initialStableCoins[1] = stableCoin2;

        IWhiteList(whiteListAddress).addStableCoins(initialStableCoins);

        bittyVault.addStableCoins(initialStableCoins);
        assertEq(bittyVault.getStableCoins().length, 2);

        address[] memory resetStableCoins = new address[](2);
        resetStableCoins[0] = stableCoin1;
        resetStableCoins[1] = stableCoin2;
        bittyVault.resetStableCoins(resetStableCoins);

        assertEq(bittyVault.getStableCoins().length, 2);
        address[] memory stableCoins = bittyVault.getStableCoins();
        assertTrue(stableCoins[0] == stableCoin1 || stableCoins[1] == stableCoin1);
        assertTrue(stableCoins[0] == stableCoin2 || stableCoins[1] == stableCoin2);
    }

    function test_ResetStableCoins_RemoveAllAndAddNew() public {
        address stableCoin1 = makeAddr("stableCoin1");
        address stableCoin2 = makeAddr("stableCoin2");
        address stableCoin3 = makeAddr("stableCoin3");
        address[] memory initialStableCoins = new address[](2);
        initialStableCoins[0] = stableCoin1;
        initialStableCoins[1] = stableCoin2;

        IWhiteList(whiteListAddress).addStableCoins(initialStableCoins);
        address[] memory newStableCoins = new address[](1);
        newStableCoins[0] = stableCoin3;
        IWhiteList(whiteListAddress).addStableCoins(newStableCoins);

        bittyVault.addStableCoins(initialStableCoins);
        assertEq(bittyVault.getStableCoins().length, 2);

        address[] memory resetStableCoins = new address[](3);
        resetStableCoins[0] = stableCoin1;
        resetStableCoins[1] = stableCoin2;
        resetStableCoins[2] = stableCoin3;
        bittyVault.resetStableCoins(resetStableCoins);

        assertEq(bittyVault.getStableCoins().length, 3);
        address[] memory stableCoins = bittyVault.getStableCoins();
        bool found1 = false;
        bool found2 = false;
        bool found3 = false;
        for (uint256 i = 0; i < stableCoins.length; i++) {
            if (stableCoins[i] == stableCoin1) found1 = true;
            if (stableCoins[i] == stableCoin2) found2 = true;
            if (stableCoins[i] == stableCoin3) found3 = true;
        }
        assertTrue(found1 && found2 && found3);
    }

    function test_ResetStableCoins_EmptyArray() public {
        address stableCoin1 = makeAddr("stableCoin1");
        address[] memory initialStableCoins = new address[](1);
        initialStableCoins[0] = stableCoin1;

        IWhiteList(whiteListAddress).addStableCoins(initialStableCoins);

        bittyVault.addStableCoins(initialStableCoins);
        assertEq(bittyVault.getStableCoins().length, 1);

        address[] memory emptyArray = new address[](0);
        bittyVault.resetStableCoins(emptyArray);

        assertEq(bittyVault.getStableCoins().length, 1);
        assertEq(bittyVault.getStableCoins()[0], stableCoin1);
    }

    function test_ResetStableCoins_RevertsIfNotWhitelisted() public {
        address stableCoin1 = makeAddr("stableCoin1");
        address stableCoin2 = makeAddr("stableCoin2");
        address[] memory initialStableCoins = new address[](1);
        initialStableCoins[0] = stableCoin1;

        IWhiteList(whiteListAddress).addStableCoins(initialStableCoins);

        bittyVault.addStableCoins(initialStableCoins);

        address[] memory resetStableCoins = new address[](2);
        resetStableCoins[0] = stableCoin1;
        resetStableCoins[1] = stableCoin2;

        vm.expectRevert(NotWhiteListed.selector);
        bittyVault.resetStableCoins(resetStableCoins);
    }

    function test_ResetStableCoins_RevertsIfNotInitialized() public {
        BittyVault newVault = new BittyVault();
        address stableCoin1 = makeAddr("stableCoin1");
        address[] memory resetStableCoins = new address[](1);
        resetStableCoins[0] = stableCoin1;

        vm.expectRevert(NotAuthorized.selector);
        newVault.resetStableCoins(resetStableCoins);
    }

    function test_ResetStableCoins_GrantorCanCallWhenNoTrustee() public {
        address stableCoin1 = makeAddr("stableCoin1");
        address[] memory resetStableCoins = new address[](1);
        resetStableCoins[0] = stableCoin1;

        IWhiteList(whiteListAddress).addStableCoins(resetStableCoins);

        bittyVault.resetStableCoins(resetStableCoins);
        assertEq(bittyVault.getStableCoins().length, 1);
        assertEq(bittyVault.getStableCoins()[0], stableCoin1);
    }

    function test_ResetStableCoins_TrusteeCanCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address stableCoin1 = makeAddr("stableCoin1");
        address[] memory resetStableCoins = new address[](1);
        resetStableCoins[0] = stableCoin1;

        IWhiteList(whiteListAddress).addStableCoins(resetStableCoins);

        bittyVault.setTrustee(trustee);

        vm.prank(trustee);
        bittyVault.resetStableCoins(resetStableCoins);
        assertEq(bittyVault.getStableCoins().length, 1);
        assertEq(bittyVault.getStableCoins()[0], stableCoin1);
    }

    function test_ResetStableCoins_GrantorCannotCallWhenTrusteeIsSet() public {
        address trustee = makeAddr("trustee");
        address stableCoin1 = makeAddr("stableCoin1");
        address[] memory resetStableCoins = new address[](1);
        resetStableCoins[0] = stableCoin1;

        IWhiteList(whiteListAddress).addStableCoins(resetStableCoins);

        bittyVault.setTrustee(trustee);

        vm.expectRevert(OnlyTrustee.selector);
        bittyVault.resetStableCoins(resetStableCoins);
    }

    function test_ResetStableCoins_UnauthorizedCannotCallWhenNoTrustee() public {
        address unauthorized = makeAddr("unauthorized");
        address stableCoin1 = makeAddr("stableCoin1");
        address[] memory resetStableCoins = new address[](1);
        resetStableCoins[0] = stableCoin1;

        IWhiteList(whiteListAddress).addStableCoins(resetStableCoins);

        vm.prank(unauthorized);
        vm.expectRevert(OnlyGrantor.selector);
        bittyVault.resetStableCoins(resetStableCoins);
    }

    function test_ResetStableCoins_MultipleStableCoins() public {
        address stableCoin1 = makeAddr("stableCoin1");
        address stableCoin2 = makeAddr("stableCoin2");
        address stableCoin3 = makeAddr("stableCoin3");
        address[] memory resetStableCoins = new address[](3);
        resetStableCoins[0] = stableCoin1;
        resetStableCoins[1] = stableCoin2;
        resetStableCoins[2] = stableCoin3;

        IWhiteList(whiteListAddress).addStableCoins(resetStableCoins);

        bittyVault.resetStableCoins(resetStableCoins);
        assertEq(bittyVault.getStableCoins().length, 3);
    }

    function test_CheckAsset_SuccessForWhiteListedAsset() public {
        MockERC20 newAsset = new MockERC20("NewAsset", "NA", 18);
        address[] memory assetArray = new address[](1);
        assetArray[0] = address(newAsset);
        IWhiteList(whiteListAddress).addAssets(assetArray);

        address[] memory assets = new address[](1);
        assets[0] = address(newAsset);
        bittyVault.addAssets(assets);

        assertTrue(bittyVault.getAssets().length > 0);
    }

    function test_CheckAsset_SuccessForWhiteListedStableCoin() public {
        MockERC20 newStableCoin = new MockERC20("NewStableCoin", "NSC", 18);
        address[] memory stableCoinArray = new address[](1);
        stableCoinArray[0] = address(newStableCoin);
        IWhiteList(whiteListAddress).addStableCoins(stableCoinArray);

        address[] memory stableCoins = new address[](1);
        stableCoins[0] = address(newStableCoin);
        bittyVault.addStableCoins(stableCoins);

        assertTrue(bittyVault.getStableCoins().length > 0);
    }

    function test_PingSuccess() public {
        bittyVault.setAutoIrrevocableAfterNoPing(1 days);
        assertTrue(bittyVault.revocable());

        bittyVault.grantorPing();
        assertTrue(bittyVault.revocable());

        vm.warp(block.timestamp + 12 hours);
        assertTrue(bittyVault.revocable());
    }

    function test_PingFailedIfAutoIrrevocableNotSet() public {
        vm.expectRevert(AutoIrrevocableAfterNoPingNotSet.selector);
        bittyVault.grantorPing();
    }

    function test_RevocableWhenAutoIrrevocableSetButNoPing() public {
        bittyVault.setAutoIrrevocableAfterNoPing(1 days);
        assertTrue(bittyVault.revocable());
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(bittyVault.revocable());
    }

    function test_RevocableWhenAutoIrrevocableSetAndPinged() public {
        bittyVault.setAutoIrrevocableAfterNoPing(1 days);
        bittyVault.grantorPing();

        assertTrue(bittyVault.revocable());

        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(bittyVault.revocable());
    }

    function test_RevocableWhenIrrevocableSet() public {
        bittyVault.setToIrrevocable();
        assertFalse(bittyVault.revocable());
    }

    function test_RevocableWhenAutoIrrevocableNotSet() public view {
        assertTrue(bittyVault.revocable());
    }

    function test_UpgradeSuccess() public {
        address upgradeToContract = makeAddr("upgradeToContract");
        bittyVault.upgrade(upgradeToContract);
    }

    function test_UpgradeFailedIfAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        bittyVault.upgrade(address(0));
    }

    function test_ReplaceTrustee_GrantorCannotCall() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        address beneficiary = makeAddr("beneficiary");
        bittyVault.setTrustee(trustee);
        bittyVault.setBeneficiary(beneficiary);
        bittyVault.setToIrrevocable();

        vm.warp(block.timestamp + 181 days);

        vm.expectRevert(OnlyBeneficiary.selector);
        bittyVault.replaceTrustee(newTrustee);
    }

    function test_SetTrusteeInvalidAfterNoPing_RevertsIfNotGrantor() public {
        address trustee = makeAddr("trustee");
        bittyVault.setTrustee(trustee);

        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(OnlyGrantor.selector);
        bittyVault.setTrusteeInvalidAfterNoPing(90 days);
    }

    function test_SetTrusteeInvalidAfterNoPing_RevertsIfNotRevocable() public {
        address trustee = makeAddr("trustee");
        bittyVault.setTrustee(trustee);
        bittyVault.setToIrrevocable();

        vm.prank(address(this));
        vm.expectRevert(OnlyRevocable.selector);
        bittyVault.setTrusteeInvalidAfterNoPing(90 days);
    }

    function test_Revocable_EdgeCase_NoPingTimeSet() public {
        bittyVault.setAutoIrrevocableAfterNoPing(1 days);

        assertTrue(bittyVault.revocable());

        vm.warp(block.timestamp + 1 days);
        assertTrue(bittyVault.revocable());

        vm.warp(block.timestamp + 1);
        assertFalse(bittyVault.revocable());
    }

    function test_Revocable_EdgeCase_PingAfterExpiry() public {
        bittyVault.setAutoIrrevocableAfterNoPing(1 days);
        vm.warp(block.timestamp + 2 days);

        assertFalse(bittyVault.revocable());

        bittyVault.grantorPing();
        assertTrue(bittyVault.revocable());
    }

    function test_SetBeneficiary_SameAddressDoesNothing() public {
        address beneficiary = makeAddr("beneficiary");
        bittyVault.setBeneficiary(beneficiary);
        bittyVault.setBeneficiary(beneficiary);
        assertEq(bittyVault.beneficiary(), beneficiary);
    }

    function test_SetBeneficiary_RevertsIfNotRevocable() public {
        address beneficiary = makeAddr("beneficiary");
        bittyVault.setToIrrevocable();

        vm.expectRevert(OnlyRevocable.selector);
        bittyVault.setBeneficiary(beneficiary);
    }

    function test_ChangeBeneficiaryAddress_RevertsIfAddressZero() public {
        address beneficiary = makeAddr("beneficiary");
        bittyVault.setBeneficiary(beneficiary);

        vm.prank(beneficiary);
        vm.expectRevert(AddressZero.selector);
        bittyVault.changeBeneficiaryAddress(address(0));
    }

    function test_ChangeBeneficiaryAddress_RevertsIfNotBeneficiary() public {
        address beneficiary = makeAddr("beneficiary");
        bittyVault.setBeneficiary(beneficiary);

        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(OnlyBeneficiary.selector);
        bittyVault.changeBeneficiaryAddress(makeAddr("newBeneficiary"));
    }

    function test_GetAllTriggerEventKeys_AfterRemoval() public {
        string[] memory eventNames = new string[](2);
        eventNames[0] = "Event1";
        eventNames[1] = "Event2";
        IBeneficiary.TriggerEvent[] memory triggerEvents = new IBeneficiary.TriggerEvent[](2);
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: makeAddr("trigger1"), amount: 1000, isPercentage: false});
        triggerEvents[1] =
            IBeneficiary.TriggerEvent({triggerAddress: makeAddr("trigger2"), amount: 2000, isPercentage: false});

        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        assertEq(bittyVault.getAllTriggerEventKeys().length, 2);

        string[] memory toRemove = new string[](1);
        toRemove[0] = "Event1";
        bittyVault.removeTriggerEvents(toRemove);

        bytes32[] memory keys = bittyVault.getAllTriggerEventKeys();
        assertEq(keys.length, 1);
    }

    function test_GetAllTimeEventKeys_AfterRemoval() public {
        uint256[] memory timestamps = new uint256[](2);
        timestamps[0] = block.timestamp + 1 days;
        timestamps[1] = block.timestamp + 2 days;
        IBeneficiary.TimeEvent[] memory timeEvents = new IBeneficiary.TimeEvent[](2);
        timeEvents[0] = IBeneficiary.TimeEvent({amount: 1000, isPercentage: false});
        timeEvents[1] = IBeneficiary.TimeEvent({amount: 2000, isPercentage: false});

        bittyVault.addTimeEvents(timestamps, timeEvents);
        assertEq(bittyVault.getAllTimeEventKeys().length, 2);

        uint256[] memory toRemove = new uint256[](1);
        toRemove[0] = timestamps[0];
        bittyVault.removeTimeEvents(toRemove);

        uint256[] memory keys = bittyVault.getAllTimeEventKeys();
        assertEq(keys.length, 1);
    }

    function test_Upgrade_RevertsIfNotInitialized() public {
        BittyVault newVault = new BittyVault();
        vm.expectRevert();
        newVault.upgrade(makeAddr("upgradeContract"));
    }

    function test_SetStartDistributionTimestamp_RevertsIfAlreadySet() public {
        uint256 timestamp1 = block.timestamp + 100 days;
        uint256 timestamp2 = block.timestamp + 200 days;

        bittyVault.setStartDistributionTimestamp(timestamp1);

        vm.expectRevert(StartDistributionTimestampAlreadySet.selector);
        bittyVault.setStartDistributionTimestamp(timestamp2);
    }

    function test_SetStartDistributionTimestamp_RevertsIfNotGrantor() public {
        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(OnlyGrantor.selector);
        bittyVault.setStartDistributionTimestamp(block.timestamp + 100 days);
    }

    function test_DistributionNotStarted_BeforeSet() public view {
        assertFalse(bittyVault.distributionStarted());
    }

    function test_GrantorPing_RevertsIfNotSet() public {
        vm.expectRevert(AutoIrrevocableAfterNoPingNotSet.selector);
        bittyVault.grantorPing();
    }

    function test_GrantorPing_RevertsIfNotGrantor() public {
        bittyVault.setAutoIrrevocableAfterNoPing(1 days);

        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(OnlyGrantor.selector);
        bittyVault.grantorPing();
    }

    function test_GrantorPing_UpdatesTimestamp() public {
        bittyVault.setAutoIrrevocableAfterNoPing(1 days);

        vm.warp(block.timestamp + 1 days);

        bittyVault.grantorPing();

        assertTrue(bittyVault.revocable());

        vm.warp(block.timestamp + 1 days);
        assertTrue(bittyVault.revocable());
    }
}
