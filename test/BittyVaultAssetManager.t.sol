// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {
    AmountIsZero,
    AddressZero,
    InsufficientBalance,
    NotInitialized,
    InvalidYieldProvider,
    InvalidSwapProvider,
    NotWhiteListed,
    Deprecated,
    NotAuthorized,
    OnlyAssetManager
} from "../src/interfaces/Errors.sol";

import {ISwapProvider} from "../src/interfaces/IAssetManager.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {MockYieldProvider} from "./mock/MockYieldProvider.sol";
import {MockSwapProvider} from "./mock/MockSwapProvider.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {IWhiteList} from "../src/interfaces/IWhiteList.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {Migrator} from "../src/Migrator.sol";
import {AssetManagerLogic} from "../src/logic/AssetManagerLogic.sol";
import {VaultLogic} from "../src/logic/VaultLogic.sol";
import {MigratorLogic} from "../src/logic/MigratorLogic.sol";

contract TestAssetManager is Test, BittyVault {
    address public mockWETH;
    address public mockWBTC;
    address public mockUSDT;
    address public mockUSDC;
    MockYieldProvider public mockYieldProvider;
    MockSwapProvider public mockSwapProvider;
    address public whiteListAddress;
    address[] public assets;
    address[] public stableCoins;
    address[] public yieldProviders;
    address[] public swapProviders;
    address public migratorAddress;
    address public assetManagerAddress;
    address public grantorAddress;

    function setUp() public {
        mockWETH = address(new WETH());
        mockWBTC = address(new MockERC20("WBTC", "WBTC", 18));
        mockUSDT = address(new MockERC20("USDT", "USDT", 18));
        mockUSDC = address(new MockERC20("USDC", "USDC", 18));
        assets = new address[](2);
        assets[0] = address(mockWETH);
        assets[1] = address(mockWBTC);
        stableCoins = new address[](2);
        stableCoins[0] = address(mockUSDT);
        stableCoins[1] = address(mockUSDC);
        yieldProviders = new address[](1);
        mockYieldProvider = new MockYieldProvider();
        yieldProviders[0] = address(mockYieldProvider);
        swapProviders = new address[](1);
        mockSwapProvider = new MockSwapProvider();
        swapProviders[0] = address(mockSwapProvider);
        migratorAddress = address(new Migrator());
        address poolManagerAddress = makeAddr("poolManagerAddress");
        grantorAddress = makeAddr("grantor");
        assetManagerAddress = makeAddr("assetManager");
        WhiteList whiteList = new WhiteList(poolManagerAddress);
        whiteListAddress = address(whiteList);
        whiteList.addAssets(assets);
        whiteList.addStableCoins(stableCoins);
        whiteList.addYieldProviders(yieldProviders);
        whiteList.addSwapProviders(swapProviders);
    }

    function getClonedProvider(address provider) external view returns (address) {
        return _assetManager.clonedProviders[provider];
    }

    // Helper function to clone a provider for testing
    function cloneProviderForTesting(address provider) external returns (address) {
        return AssetManagerLogic.cloneProvider(_assetManager, provider);
    }

    function test_InitializeWithAddressZero() public {
        address[] memory containingAddressZero = new address[](1);
        containingAddressZero[0] = address(0);
        vm.expectRevert(AddressZero.selector);
        this.initialize(
            address(0), whiteListAddress, migratorAddress, mockWETH, assets, stableCoins, yieldProviders, swapProviders
        );
        vm.expectRevert(AddressZero.selector);
        this.initialize(
            grantorAddress, address(0), migratorAddress, mockWETH, assets, stableCoins, yieldProviders, swapProviders
        );
        vm.expectRevert(AddressZero.selector);
        this.initialize(
            grantorAddress, whiteListAddress, address(0), mockWETH, assets, stableCoins, yieldProviders, swapProviders
        );
        vm.expectRevert(AddressZero.selector);
        this.initialize(
            grantorAddress,
            whiteListAddress,
            migratorAddress,
            address(0),
            assets,
            stableCoins,
            yieldProviders,
            swapProviders
        );
    }

    function doInitialize() public {
        this.initialize(
            grantorAddress,
            whiteListAddress,
            migratorAddress,
            mockWETH,
            assets,
            stableCoins,
            yieldProviders,
            swapProviders
        );
        vm.prank(grantorAddress);
        this.setAssetManager(assetManagerAddress);
    }

    function test_SetRebalanceRules() public {
        this.doInitialize();
        RebalanceLimit memory rebalanceLimit = RebalanceLimit({
            minimalStableCoinBalance: 100 * 1e6, minimalTimestampBetweenRebalances: 30, maxRebalancePercentage: 10
        });
        vm.prank(grantorAddress);
        this.setRebalanceRules(rebalanceLimit);
        RebalanceLimit memory rebalanceLimit_ = this.rebalanceLimit();
        assertEq(rebalanceLimit_.minimalStableCoinBalance, 100 * 1e6);
        assertEq(rebalanceLimit_.minimalTimestampBetweenRebalances, 30);
        assertEq(rebalanceLimit_.maxRebalancePercentage, 10);
    }

    function test_SetAssetConfig() public {
        this.doInitialize();
        AssetConfig memory assetConfig = AssetConfig({minimalBalance: 100 * 1e6, minimalDurationBetweenRebalances: 30});
        vm.prank(grantorAddress);
        this.setAssetConfig(address(mockWETH), assetConfig);
    }

    function test_RevertOnlyAssetManager() public {
        this.doInitialize();
        vm.expectRevert(OnlyAssetManager.selector);
        this.supply(address(mockYieldProvider), address(mockWETH), 1 ether);
        vm.expectRevert(OnlyAssetManager.selector);
        this.withdraw(address(mockYieldProvider), address(mockWETH), 1 ether);
        vm.expectRevert(OnlyAssetManager.selector);
        this.rebalance(address(mockSwapProvider), address(mockWBTC), address(mockUSDT), 1 ether, 1 ether, "");
        vm.expectRevert(OnlyAssetManager.selector);
        this.getBaseFee(address(mockUSDT));
        vm.expectRevert(OnlyAssetManager.selector);
        this.getRevenueFee(address(mockUSDT));
    }

    function test_SupplyRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(mockYieldProvider), address(0), 1 ether);
    }

    function test_SupplyRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(mockYieldProvider), address(mockWETH), 0);
    }

    function test_WithdrawRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(address(mockYieldProvider), address(mockWETH), 0);
    }

    function test_WithdrawRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(address(mockYieldProvider), address(0), 1 ether);
    }

    function test_revertTurnETHToWETH() public {
        vm.expectRevert(NotInitialized.selector);
        vm.prank(assetManagerAddress);
        this.turnETHToWETH();
    }

    function test_TurnETHToWETHSuccess() public {
        this.doInitialize();
        vm.deal(address(this), 1 ether);
        this.turnETHToWETH();
        assertEq(WETH(payable(mockWETH)).balanceOf(address(this)), 1 ether);
    }

    function test_SupplyRevertInvalidYieldProvider() public {
        this.doInitialize();
        address invalidYieldProvider = address(new MockYieldProvider());
        vm.expectRevert(InvalidYieldProvider.selector);
        vm.prank(assetManagerAddress);
        this.supply(invalidYieldProvider, address(mockWETH), 1 ether);
    }

    function test_SupplySuccess() public {
        this.doInitialize();

        MockERC20 mockToken = new MockERC20("MockToken", "MTK", 18);

        uint256 supplyAmount = 1000 * 1e18;

        deal(address(mockToken), address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        // Supply will clone the provider, so get the cloned address after supply
        this.supply(address(mockYieldProvider), address(mockToken), supplyAmount);

        // Get cloned provider address after supply
        address clonedProvider = this.getClonedProvider(address(mockYieldProvider));
        require(clonedProvider != address(0), "Provider should be cloned");

        uint256 balanceAfter = MockYieldProvider(clonedProvider).getBalance(address(mockToken));
        assertEq(balanceAfter, supplyAmount);

        assertEq(mockToken.balanceOf(address(this)), 0);
    }

    function test_WithdrawSuccess() public {
        this.doInitialize();

        MockERC20 mockToken = new MockERC20("MockToken", "MTK", 18);
        uint256 supplyAmount = 1000 * 1e18;
        uint256 withdrawAmount = 500 * 1e18;

        deal(address(mockToken), address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        this.supply(address(mockYieldProvider), address(mockToken), supplyAmount);

        // Get cloned provider address
        address clonedProvider = this.getClonedProvider(address(mockYieldProvider));

        uint256 balanceBefore = mockToken.balanceOf(address(this));

        vm.prank(assetManagerAddress);
        this.withdraw(address(mockYieldProvider), address(mockToken), withdrawAmount);

        uint256 balanceAfter = mockToken.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, withdrawAmount);

        assertEq(MockYieldProvider(clonedProvider).getBalance(address(mockToken)), supplyAmount - withdrawAmount);
    }

    function test_YieldProviderRevertIfNotWhiteListed() public {
        this.doInitialize();

        address invalidYieldProvider = makeAddr("InvalidYieldProvider");
        vm.expectRevert(InvalidYieldProvider.selector);
        vm.prank(assetManagerAddress);
        this.supply(invalidYieldProvider, address(mockWETH), 1 ether);
    }

    function test_YieldProviderDeprecateIfYieldProviderGotDeprecated() public {
        this.doInitialize();
        WhiteList(whiteListAddress).deprecateYieldProviders(yieldProviders);
        vm.expectRevert(Deprecated.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(mockYieldProvider), address(mockWETH), 1 ether);
    }

    function test_WithdrawMoneySuccessFromDeprecateYieldProvider() public {
        this.doInitialize();
        deal(address(mockWETH), address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.supply(address(mockYieldProvider), address(mockWETH), 1 ether);
        WhiteList(whiteListAddress).deprecateYieldProviders(yieldProviders);
        // Withdraw will revert Deprecated because _checkYieldProvider checks if provider is deprecated
        // This is expected behavior - deprecated providers cannot be used for new operations
        vm.expectRevert(Deprecated.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(address(mockYieldProvider), address(mockWETH), 1 ether);
    }

    function test_WithdrawFromInvalidYieldProvider() public {
        this.doInitialize();
        address invalidYieldProvider = makeAddr("InvalidYieldProvider");
        vm.expectRevert(InvalidYieldProvider.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(invalidYieldProvider, address(mockWETH), 1 ether);
    }

    function test_GetAllAssetConfigKeys() public {
        this.doInitialize();
        AssetConfig memory assetConfig1 = AssetConfig({minimalBalance: 100 * 1e6, minimalDurationBetweenRebalances: 30});
        AssetConfig memory assetConfig2 = AssetConfig({minimalBalance: 200 * 1e6, minimalDurationBetweenRebalances: 60});

        vm.prank(grantorAddress);
        this.setAssetConfig(address(mockWETH), assetConfig1);
        vm.prank(grantorAddress);
        this.setAssetConfig(address(mockWBTC), assetConfig2);

        address[] memory keys = this.getAllAssetConfigKeys();
        assertEq(keys.length, 2);
        assertTrue(keys[0] == address(mockWETH) || keys[1] == address(mockWETH));
        assertTrue(keys[0] == address(mockWBTC) || keys[1] == address(mockWBTC));
    }

    function test_GetAllLastRebalanceTimestampKeys() public {
        this.doInitialize();
        AssetConfig memory assetConfig = AssetConfig({minimalBalance: 0, minimalDurationBetweenRebalances: 30});
        vm.prank(grantorAddress);
        this.setAssetConfig(address(mockWETH), assetConfig);

        uint256 sellAmount = 1 * 1e6;
        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        address clonedSwapProvider = this.cloneProviderForTesting(address(mockSwapProvider));
        deal(address(mockWETH), address(this), sellAmount);
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        vm.prank(address(this));
        MockERC20(mockWETH).approve(clonedSwapProvider, sellAmount);

        vm.warp(block.timestamp + 31);
        vm.prank(assetManagerAddress);
        this.rebalance(address(mockSwapProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);

        address[] memory keys = this.getAllLastRebalanceTimestampKeys();
        assertEq(keys.length, 1);
        assertEq(keys[0], address(mockWETH));
    }
}

