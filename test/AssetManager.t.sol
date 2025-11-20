// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {AssetManager} from "../src/AssetManager.sol";
import {ITrust} from "../src/interfaces/ITrust.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {console} from "lib/forge-std/src/console.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {
    AmountIsZero,
    AddressZero,
    InsufficientBalance,
    NotInitialized,
    WETHNotSet,
    InvalidGrantor,
    InvalidYieldProvider,
    InvalidSwapProvider,
    InvalidAssetType
} from "../src/interfaces/Errors.sol";

import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IYieldProvider, ISwapProvider} from "../src/interfaces/IAssetManager.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

import {MockWETH} from "./mock/MockWETH.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {MockYieldProvider} from "./mock/MockYieldProvider.sol";
import {MockSwapProvider} from "./mock/MockSwapProvider.sol";

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

    MockYieldProvider public mockYieldProvider;
    MockSwapProvider public mockSwapProvider;

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

    function initialize(
        address wethAddress,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory yieldProviders_,
        address[] memory swapProviders_
    ) public initializer {
        _initialize(wethAddress, assetAddresses, stableCoinAddresses, yieldProviders_, swapProviders_);
    }

    function setUp() public {
        mockWETH = address(new MockWETH());
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
        assertEq(_yieldProviders[address(mockYieldProvider)], true);
        assertEq(_swapProviders[address(mockSwapProvider)], true);
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

    function test_SupplyRevertInvalidYieldProvider() public {
        this.doInitialize();
        address invalidYieldProvider = address(new MockYieldProvider());
        vm.expectRevert(InvalidYieldProvider.selector);
        this.supply(invalidYieldProvider, address(mockWETH), 1 ether);
    }

    function test_Supply() public {
        this.doInitialize();

        MockERC20 mockToken = new MockERC20("MockToken", "MTK", 18);

        uint256 supplyAmount = 1000 * 1e18;

        deal(address(mockToken), address(this), supplyAmount);

        uint256 balanceBefore = mockYieldProvider.getBalance(address(mockToken));

        this.supply(address(mockYieldProvider), address(mockToken), supplyAmount);

        uint256 balanceAfter = mockYieldProvider.getBalance(address(mockToken));
        assertEq(balanceAfter - balanceBefore, supplyAmount);

        assertEq(mockToken.balanceOf(address(this)), 0);
    }

    function test_Withdraw() public {
        this.doInitialize();

        MockERC20 mockToken = new MockERC20("MockToken", "MTK", 18);
        uint256 supplyAmount = 1000 * 1e18;
        uint256 withdrawAmount = 500 * 1e18;

        deal(address(mockToken), address(this), supplyAmount);
        this.supply(address(mockYieldProvider), address(mockToken), supplyAmount);

        uint256 balanceBefore = mockToken.balanceOf(address(this));

        this.withdraw(address(mockYieldProvider), address(mockToken), withdrawAmount);

        uint256 balanceAfter = mockToken.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, withdrawAmount);

        assertEq(mockYieldProvider.getBalance(address(mockToken)), supplyAmount - withdrawAmount);
    }

    function test_SwapERC20ToERC20() public {
        this.doInitialize();

        MockERC20 sellToken = new MockERC20("SellToken", "STK", 18);

        uint256 sellAmount = 1000 * 1e18;
        uint256 buyAmount = 2000 * 1e18; // 1:2 exchange rate
        uint256 buyAmountMin = 1500 * 1e18;

        deal(address(sellToken), address(this), sellAmount);

        sellToken.approve(address(mockSwapProvider), sellAmount);

        deal(address(mockUSDT), address(mockSwapProvider), buyAmount);

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

        vm.expectRevert(InvalidAssetType.selector);
        this.swap(address(mockSwapProvider), abi.encode(address(mockWETH), sellAmount, address(buyToken), buyAmountMin));
    }

    function test_SwapERC20ToETH() public {
        this.doInitialize();

        MockERC20 sellToken = new MockERC20("SellToken", "STK", 18);

        uint256 sellAmount = 1000 * 1e18;
        uint256 buyAmount = 0.5 ether; // 1000 tokens = 0.5 ETH
        uint256 buyAmountMin = 0.4 ether;

        deal(address(sellToken), address(this), sellAmount);

        sellToken.approve(address(mockSwapProvider), sellAmount);

        deal(address(mockWETH), address(mockSwapProvider), buyAmount);

        uint256 sellBalanceBefore = sellToken.balanceOf(address(this));
        uint256 wethBalanceBefore = MockWETH(mockWETH).balanceOf(address(this));

        this.swap(
            address(mockSwapProvider), abi.encode(address(sellToken), sellAmount, address(mockWETH), buyAmountMin)
        );

        uint256 sellBalanceAfter = sellToken.balanceOf(address(this));
        assertEq(sellBalanceBefore - sellBalanceAfter, sellAmount);

        uint256 wethBalanceAfter = MockWETH(mockWETH).balanceOf(address(this));
        assertGe(wethBalanceAfter - wethBalanceBefore, buyAmountMin);
    }
}

