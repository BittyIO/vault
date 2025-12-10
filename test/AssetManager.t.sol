// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {AssetManager} from "../src/AssetManager.sol";
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
    Deprecated
} from "../src/interfaces/Errors.sol";

import {ISwapProvider} from "../src/interfaces/IAssetManager.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {MockYieldProvider} from "./mock/MockYieldProvider.sol";
import {MockSwapProvider} from "./mock/MockSwapProvider.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {IWhiteList} from "../src/interfaces/IWhiteList.sol";

contract TestAssetManager is Test, AssetManager {
    using SafeERC20 for IERC20;
    using Address for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    address public mockWETH;
    address public mockWBTC;
    address public mockUSDT;
    address public mockUSDC;
    address[] public assets;
    address[] public stableCoins;
    address[] public yieldProviders;
    address[] public swapProviders;
    address public whiteListAddress;

    MockYieldProvider public mockYieldProvider;
    MockSwapProvider public mockSwapProvider;

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
        whiteListAddress = address(new WhiteList());
        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addAssets(assets);
        IWhiteList(whiteListAddress).addStableCoins(stableCoins);
        IWhiteList(whiteListAddress).addYieldProviders(yieldProviders);
        IWhiteList(whiteListAddress).addSwapProviders(swapProviders);
        vm.stopPrank();
    }

    function setRebalanceRules(RebalanceLimit memory rebalanceLimit) external {
        _setRebalanceRules(rebalanceLimit);
    }

    function turnETHToWETH() external {
        _turnETHToWETH();
    }

    function swap(address swapProvider, bytes memory data) external {
        (address sellAssetAddress, uint256 sellAmount, address buyAssetAddress, uint256 buyAmountMin) =
            abi.decode(data, (address, uint256, address, uint256));
        _swap(swapProvider, sellAssetAddress, sellAmount, buyAssetAddress, buyAmountMin, data);
    }

    function supply(address yieldProvider, address assetAddress, uint256 amount) external {
        _supply(yieldProvider, assetAddress, amount);
    }

    function withdraw(address yieldProvider, address assetAddress, uint256 amount) external {
        _withdraw(yieldProvider, assetAddress, amount);
    }

    function rebalance(
        address swapProvider,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external {
        _rebalance(swapProvider, from, to, sellAmount, buyAmountMin, data);
    }

    function getClonedProvider(address provider) external view returns (address) {
        return clonedProviders[provider];
    }

    // Helper function to clone a provider for testing
    function cloneProviderForTesting(address provider) external returns (address) {
        return _cloneProvider(provider);
    }

    function initialize(
        address wethAddress,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory yieldProviders_,
        address[] memory swapProviders_
    ) public initializer {
        _initialize(wethAddress, whiteListAddress, assetAddresses, stableCoinAddresses, yieldProviders_, swapProviders_);
    }

    function test_RevertNotInitialized() public {
        vm.expectRevert(NotInitialized.selector);
        this.turnETHToWETH();
        vm.expectRevert(NotInitialized.selector);
        this.setRebalanceRules(
            RebalanceLimit({
                minimalStableCoinBalance: 100 * 1e6, minimalTimestampBetweenRebalances: 30, maxRebalancePercentage: 10
            })
        );
        vm.expectRevert(NotInitialized.selector);
        this.supply(address(mockYieldProvider), address(0), 1 ether);
        vm.expectRevert(NotInitialized.selector);
        this.withdraw(address(mockYieldProvider), address(0), 1 ether);
        vm.expectRevert(NotInitialized.selector);
        this.swap(address(mockSwapProvider), abi.encode(address(0), 1 ether, address(mockUSDT), 1 ether));
        vm.expectRevert(NotInitialized.selector);
        this.rebalance(address(mockSwapProvider), address(mockWBTC), address(mockUSDT), 1 ether, 1 ether, "");
    }

    function doInitialize() public {
        if (address(mockYieldProvider) == address(0)) {
            mockYieldProvider = new MockYieldProvider();
        }
        if (address(mockSwapProvider) == address(0)) {
            mockSwapProvider = new MockSwapProvider();
        }
        this.initialize(address(mockWETH), assets, stableCoins, yieldProviders, swapProviders);
    }

    function test_InitializeWithAddressZero() public {
        address[] memory containingAddressZero = new address[](1);
        containingAddressZero[0] = address(0);
        vm.expectRevert(AddressZero.selector);
        this.initialize(address(0), assets, stableCoins, yieldProviders, swapProviders);
        vm.expectRevert(AddressZero.selector);
        this.initialize(address(mockWETH), containingAddressZero, stableCoins, yieldProviders, swapProviders);
        vm.expectRevert(AddressZero.selector);
        this.initialize(address(mockWETH), assets, containingAddressZero, yieldProviders, swapProviders);
        vm.expectRevert(AddressZero.selector);
        this.initialize(address(mockWETH), assets, stableCoins, containingAddressZero, swapProviders);
        vm.expectRevert(AddressZero.selector);
        this.initialize(address(mockWETH), assets, stableCoins, yieldProviders, containingAddressZero);
    }

    function test_Initialize() public {
        this.doInitialize();
        assertEq(wethAddress, address(mockWETH));
        assertEq(_assets.length(), 2);
        assertEq(_assets.at(0), address(mockWETH));
        assertEq(_assets.at(1), address(mockWBTC));
        assertEq(_stableCoins.length(), 2);
        assertEq(_stableCoins.at(0), address(mockUSDT));
        assertEq(_stableCoins.at(1), address(mockUSDC));
        assertTrue(_yieldProviders.contains(address(mockYieldProvider)));
        assertTrue(_swapProviders.contains(address(mockSwapProvider)));
    }

    function test_SetRebalanceRules() public {
        this.doInitialize();
        RebalanceLimit memory rebalanceLimit = RebalanceLimit({
            minimalStableCoinBalance: 100 * 1e6, minimalTimestampBetweenRebalances: 30, maxRebalancePercentage: 10
        });
        this.setRebalanceRules(rebalanceLimit);
        (uint256 minimalStableCoinBalance, uint256 minimalTimestampBetweenRebalances, uint256 maxRebalancePercentage) =
            this.rebalanceLimit();
        assertEq(minimalStableCoinBalance, 100 * 1e6);
        assertEq(minimalTimestampBetweenRebalances, 30);
        assertEq(maxRebalancePercentage, 10);
    }

    function test_SupplyRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        this.supply(address(mockYieldProvider), address(0), 1 ether);
    }

    function test_SupplyRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        this.supply(address(mockYieldProvider), address(mockWETH), 0);
    }

    function test_WithdrawRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        this.withdraw(address(mockYieldProvider), address(mockWETH), 0);
    }

    function test_WithdrawRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        this.withdraw(address(mockYieldProvider), address(0), 1 ether);
    }

    function test_SwapRevertInvalidSwapProvider() public {
        this.doInitialize();
        address invalidSwapProvider = address(new MockSwapProvider());
        vm.expectRevert(InvalidSwapProvider.selector);
        this.swap(invalidSwapProvider, abi.encode(address(0), 1 ether, address(mockUSDT), 1 ether));
    }

    function test_SwapRevertAmountIsZero() public {
        this.doInitialize();

        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = 0;

        vm.expectRevert(AmountIsZero.selector);
        this.swap(address(mockSwapProvider), abi.encode(address(0), sellAmount, address(mockUSDT), buyAmountMin));
    }

    function test_SwapRevertInsufficientBalance() public {
        this.doInitialize();

        vm.deal(address(this), 0);

        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = 1;

        vm.expectRevert(InsufficientBalance.selector);
        this.swap(address(mockSwapProvider), abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmountMin));
    }

    function test_revertTurnETHToWETH() public {
        vm.expectRevert(NotInitialized.selector);
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
        this.supply(invalidYieldProvider, address(mockWETH), 1 ether);
    }

    function test_SupplySuccess() public {
        this.doInitialize();

        MockERC20 mockToken = new MockERC20("MockToken", "MTK", 18);

        uint256 supplyAmount = 1000 * 1e18;

        deal(address(mockToken), address(this), supplyAmount);

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
        this.supply(address(mockYieldProvider), address(mockToken), supplyAmount);

        // Get cloned provider address
        address clonedProvider = this.getClonedProvider(address(mockYieldProvider));

        uint256 balanceBefore = mockToken.balanceOf(address(this));

        this.withdraw(address(mockYieldProvider), address(mockToken), withdrawAmount);

        uint256 balanceAfter = mockToken.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, withdrawAmount);

        assertEq(MockYieldProvider(clonedProvider).getBalance(address(mockToken)), supplyAmount - withdrawAmount);
    }

    function test_SwapERC20ToERC20() public {
        this.doInitialize();

        MockERC20 sellToken = new MockERC20("SellToken", "STK", 18);

        uint256 sellAmount = 1000 * 1e18;
        uint256 buyAmount = 2000 * 1e18; // 1:2 exchange rate
        uint256 buyAmountMin = 1500 * 1e18;

        deal(address(sellToken), address(this), sellAmount);

        // Pre-clone the swap provider so we can fund it
        address clonedSwapProvider = this.cloneProviderForTesting(address(mockSwapProvider));

        // Fund the cloned swap provider with buy tokens
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);

        // Approve the cloned swap provider to transfer sell tokens from TestAssetManager
        sellToken.approve(clonedSwapProvider, sellAmount);

        bytes memory swapData = abi.encode(address(sellToken), sellAmount, address(mockUSDT), buyAmount);

        uint256 sellBalanceBefore = sellToken.balanceOf(address(this));
        uint256 buyBalanceBefore = IERC20(address(mockUSDT)).balanceOf(address(this));

        this.swap(address(mockSwapProvider), swapData);

        uint256 sellBalanceAfter = sellToken.balanceOf(address(this));
        assertEq(sellBalanceBefore - sellBalanceAfter, sellAmount);

        uint256 buyBalanceAfter = IERC20(address(mockUSDT)).balanceOf(address(this));
        assertGe(buyBalanceAfter - buyBalanceBefore, buyAmountMin);
    }

    function test_SwapETHToERC20ToInvalidAsset() public {
        this.doInitialize();

        uint256 sellAmount = 1 ether;
        uint256 buyAmount = 2000 * 1e18; // 1 ETH = 2000 tokens
        uint256 buyAmountMin = 1500 * 1e18;

        vm.deal(address(this), sellAmount);

        MockERC20 buyToken = new MockERC20("BuyToken", "BTK", 18);

        deal(address(buyToken), address(mockSwapProvider), buyAmount);

        vm.expectRevert(NotWhiteListed.selector);
        this.swap(address(mockSwapProvider), abi.encode(address(mockWETH), sellAmount, address(buyToken), buyAmountMin));
    }

    function test_SwapERC20ToETH() public {
        this.doInitialize();

        MockERC20 sellToken = new MockERC20("SellToken", "STK", 18);

        uint256 sellAmount = 1000 * 1e18;
        uint256 buyAmount = 0.5 ether; // 1000 tokens = 0.5 ETH
        uint256 buyAmountMin = 0.4 ether;

        deal(address(sellToken), address(this), sellAmount);

        // Pre-clone the swap provider so we can fund it
        address clonedSwapProvider = this.cloneProviderForTesting(address(mockSwapProvider));

        // Fund the cloned swap provider with buy tokens (WETH)
        deal(address(mockWETH), clonedSwapProvider, buyAmount);

        // Approve the cloned swap provider to transfer sell tokens from TestAssetManager
        sellToken.approve(clonedSwapProvider, sellAmount);

        uint256 sellBalanceBefore = sellToken.balanceOf(address(this));
        uint256 wethBalanceBefore = WETH(payable(mockWETH)).balanceOf(address(this));

        this.swap(
            address(mockSwapProvider), abi.encode(address(sellToken), sellAmount, address(mockWETH), buyAmountMin)
        );

        uint256 sellBalanceAfter = sellToken.balanceOf(address(this));
        assertEq(sellBalanceBefore - sellBalanceAfter, sellAmount);

        uint256 wethBalanceAfter = WETH(payable(mockWETH)).balanceOf(address(this));
        assertGe(wethBalanceAfter - wethBalanceBefore, buyAmountMin);
    }

    function test_SwapFailedIfToAssetIsNotSelectedByUser() public {
        this.doInitialize();

        MockERC20 sellToken = new MockERC20("SellToken", "STK", 18);

        uint256 sellAmount = 1000 * 1e18;
        uint256 buyAmount = 2000 * 1e18; // 1:2 exchange rate
        uint256 buyAmountMin = 1500 * 1e18;

        MockERC20 buyToken = new MockERC20("BuyToken", "BTK", 18);
        deal(address(buyToken), address(mockSwapProvider), buyAmount);

        vm.expectRevert(NotWhiteListed.selector);
        this.swap(
            address(mockSwapProvider), abi.encode(address(sellToken), sellAmount, address(buyToken), buyAmountMin)
        );
    }

    function test_SwapFailedIfToAssetIsNotWhiteListed() public {
        this.doInitialize();

        MockERC20 sellToken = new MockERC20("SellToken", "STK", 18);

        uint256 sellAmount = 1000 * 1e18;
        uint256 buyAmount = 2000 * 1e18;
        uint256 buyAmountMin = 1500 * 1e18;
        deal(address(sellToken), address(this), sellAmount);
        sellToken.approve(address(mockSwapProvider), sellAmount);
        deal(address(mockWETH), address(mockSwapProvider), buyAmount);
        address[] memory removedAssets = new address[](1);
        removedAssets[0] = address(mockWETH);
        vm.prank(tx.origin);
        IWhiteList(whiteListAddress).removeAssets(removedAssets);
        vm.expectRevert(NotWhiteListed.selector);
        this.swap(
            address(mockSwapProvider), abi.encode(address(sellToken), sellAmount, address(mockWETH), buyAmountMin)
        );
    }

    function test_YieldProviderRevertIfNotWhiteListed() public {
        this.doInitialize();

        address invalidYieldProvider = makeAddr("InvalidYieldProvider");
        vm.expectRevert(InvalidYieldProvider.selector);
        this.supply(invalidYieldProvider, address(mockWETH), 1 ether);
    }

    function test_YieldProviderDeprecateIfYieldProviderGotDeprecated() public {
        this.doInitialize();
        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).deprecateYieldProviders(yieldProviders);
        vm.stopPrank();
        vm.expectRevert(Deprecated.selector);
        this.supply(address(mockYieldProvider), address(mockWETH), 1 ether);
    }

    function test_WithdrawMoneySuccessFromDeprecateYieldProvider() public {
        this.doInitialize();
        deal(address(mockWETH), address(this), 1 ether);
        this.supply(address(mockYieldProvider), address(mockWETH), 1 ether);
        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).deprecateYieldProviders(yieldProviders);
        vm.stopPrank();
        this.withdraw(address(mockYieldProvider), address(mockWETH), 1 ether);
        assertEq(WETH(payable(mockWETH)).balanceOf(address(this)), 1 ether);
    }

    function test_WithdrawFromInvalidYieldProvider() public {
        this.doInitialize();
        address invalidYieldProvider = makeAddr("InvalidYieldProvider");
        vm.expectRevert(InvalidYieldProvider.selector);
        this.withdraw(invalidYieldProvider, address(mockWETH), 1 ether);
    }
}

