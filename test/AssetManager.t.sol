// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {AssetManager} from "../src/AssetManager.sol";
import {ITrust} from "../src/interfaces/ITrust.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {console} from "lib/forge-std/src/console.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {
    AmountIsZero,
    AddressZero,
    InsufficientBalance,
    MinimalWBTCBalanceLimit,
    MinimalWETHBalanceLimit,
    MinimalStableCoinBalanceLimit,
    WETHNotSet,
    NotInitialized
} from "../src/interfaces/Errors.sol";

import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ILendingProvider, ISwapProvider} from "../src/interfaces/IAssetManager.sol";

import {MockWETH} from "./mock/MockWETH.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {MockLendingProvider} from "./mock/MockLendingProvider.sol";
import {MockSwapProvider} from "./mock/MockSwapProvider.sol";

contract TestAssetManager is Test, AssetManager {
    using SafeERC20 for IERC20;
    using Address for address;
    address public mockWETH;
    address public mockWBTC;
    address public mockUSDT;
    address public mockUSDC;

    MockLendingProvider public mockLendingProvider;
    MockSwapProvider public mockSwapProvider;

    function setRebalanceRules(RebalanceLimit memory rebalanceLimit) external {
        _setRebalanceRules(rebalanceLimit);
    }

    function turnETHToWETH() external {
        _turnETHToWETH();
    }

    function swap(bytes memory data) external {
        (address sellAssetAddress, uint256 sellAmount, address buyAssetAddress, uint256 buyAmountMin) =
            abi.decode(data, (address, uint256, address, uint256));
        _swap(sellAssetAddress, sellAmount, buyAssetAddress, buyAmountMin, data);
    }

    function supply(address assetAddress, uint256 amount) external {
        _supply(assetAddress, amount);
    }

    function withdraw(address assetAddress, uint256 amount) external {
        _withdraw(assetAddress, amount);
    }

    function rebalance(AssetType from, AssetType to, uint256 sellAmount, uint256 buyAmountMin, bytes memory data)
        external
    {
        _rebalance(from, to, sellAmount, buyAmountMin, data);
    }

    function initialize(
        address wethAddress,
        address wbtcAddress,
        address usdtAddress,
        address usdcAddress,
        address lendingProvider_,
        address swapProvider_
    ) public initializer {
        _initialize(
            wethAddress, wbtcAddress, usdtAddress, usdcAddress, address(lendingProvider_), address(swapProvider_)
        );
    }

    // Helper function to set assets for testing
    function setAsset(AssetType assetType, address assetAddress) external {
        _assets[assetType] = assetAddress;
    }

    function setUp() public {
        mockWETH = address(new MockWETH());
        mockWBTC = address(new MockERC20("WBTC", "WBTC", 18));
        mockUSDT = address(new MockERC20("USDT", "USDT", 18));
        mockUSDC = address(new MockERC20("USDC", "USDC", 18));
    }

    function test_RevertNotInitialized() public {
        vm.expectRevert(NotInitialized.selector);
        this.turnETHToWETH();
        vm.expectRevert(NotInitialized.selector);
        this.setRebalanceRules(
            RebalanceLimit({
                minimalWBTCBalance: 1 * 1e8,
                minimalWETHBalance: 100 * 1e18,
                minimalStableCoinBalance: 100 * 1e6,
                minimalTimestampBetweenRebalances: 30,
                maxRebalancePercentage: 10
            })
        );
        vm.expectRevert(NotInitialized.selector);
        this.supply(address(0), 1 ether);
        vm.expectRevert(NotInitialized.selector);
        this.withdraw(address(0), 1 ether);
        vm.expectRevert(NotInitialized.selector);
        this.swap(abi.encode(address(0), 1 ether, address(mockUSDT), 1 ether));
        vm.expectRevert(NotInitialized.selector);
        this.rebalance(AssetType.USDT, AssetType.USDC, 1 ether, 1 ether, "");
    }

    function doInitialize() public {
        if (address(mockLendingProvider) == address(0)) {
            mockLendingProvider = new MockLendingProvider();
        }
        if (address(mockSwapProvider) == address(0)) {
            mockSwapProvider = new MockSwapProvider();
        }
        this.initialize(
            address(mockWETH),
            address(mockWBTC),
            address(mockUSDT),
            address(mockUSDC),
            address(mockLendingProvider),
            address(mockSwapProvider)
        );
    }

    function test_InitializeWithAddressZero() public {
        MockLendingProvider testLendingProvider = new MockLendingProvider();
        MockSwapProvider testSwapProvider = new MockSwapProvider();

        uint256 snapshot = vm.snapshot();
        this.initialize(
            address(0),
            address(mockWBTC),
            address(mockUSDT),
            address(mockUSDC),
            address(testLendingProvider),
            address(testSwapProvider)
        );
        assertEq(assets(AssetType.WETH), address(0));
        assertEq(assets(AssetType.WBTC), address(mockWBTC));
        assertEq(assets(AssetType.USDT), address(mockUSDT));
        assertEq(assets(AssetType.USDC), address(mockUSDC));
        assertEq(address(lendingProvider), address(testLendingProvider));
        assertEq(address(swapProvider), address(testSwapProvider));
        vm.revertTo(snapshot);
        this.initialize(
            address(mockWETH),
            address(0),
            address(mockUSDT),
            address(mockUSDC),
            address(testLendingProvider),
            address(testSwapProvider)
        );
        assertEq(assets(AssetType.WETH), address(mockWETH));
        assertEq(assets(AssetType.WBTC), address(0));
        assertEq(assets(AssetType.USDT), address(mockUSDT));
        assertEq(assets(AssetType.USDC), address(mockUSDC));
        assertEq(address(lendingProvider), address(testLendingProvider));
        assertEq(address(swapProvider), address(testSwapProvider));
        vm.revertTo(snapshot);
        this.initialize(
            address(mockWETH),
            address(mockWBTC),
            address(0),
            address(mockUSDC),
            address(testLendingProvider),
            address(testSwapProvider)
        );
        assertEq(assets(AssetType.WETH), address(mockWETH));
        assertEq(assets(AssetType.WBTC), address(mockWBTC));
        assertEq(assets(AssetType.USDT), address(0));
        assertEq(assets(AssetType.USDC), address(mockUSDC));
        assertEq(address(lendingProvider), address(testLendingProvider));
        assertEq(address(swapProvider), address(testSwapProvider));
        vm.revertTo(snapshot);
        this.initialize(
            address(mockWETH),
            address(mockWBTC),
            address(mockUSDT),
            address(0),
            address(testLendingProvider),
            address(testSwapProvider)
        );
        assertEq(assets(AssetType.WETH), address(mockWETH));
        assertEq(assets(AssetType.WBTC), address(mockWBTC));
        assertEq(assets(AssetType.USDT), address(mockUSDT));
        assertEq(assets(AssetType.USDC), address(0));
        assertEq(address(lendingProvider), address(testLendingProvider));
        assertEq(address(swapProvider), address(testSwapProvider));
        vm.revertTo(snapshot);
        this.initialize(
            address(mockWETH),
            address(mockWBTC),
            address(mockUSDT),
            address(mockUSDC),
            address(0),
            address(testSwapProvider)
        );
        assertEq(assets(AssetType.WETH), address(mockWETH));
        assertEq(assets(AssetType.WBTC), address(mockWBTC));
        assertEq(assets(AssetType.USDT), address(mockUSDT));
        assertEq(assets(AssetType.USDC), address(mockUSDC));
        assertEq(address(lendingProvider), address(0));
        assertEq(address(swapProvider), address(testSwapProvider));
        vm.revertTo(snapshot);
        this.initialize(
            address(mockWETH),
            address(mockWBTC),
            address(mockUSDT),
            address(mockUSDC),
            address(testLendingProvider),
            address(0)
        );
        assertEq(assets(AssetType.WETH), address(mockWETH));
        assertEq(assets(AssetType.WBTC), address(mockWBTC));
        assertEq(assets(AssetType.USDT), address(mockUSDT));
        assertEq(assets(AssetType.USDC), address(mockUSDC));
        assertEq(address(lendingProvider), address(testLendingProvider));
        assertEq(address(swapProvider), address(0));
    }

    function test_Initialize() public {
        this.doInitialize();
        assertEq(assets(AssetType.WETH), address(mockWETH));
        assertEq(assets(AssetType.WBTC), address(mockWBTC));
        assertEq(assets(AssetType.USDT), address(mockUSDT));
        assertEq(assets(AssetType.USDC), address(mockUSDC));
        assertEq(address(lendingProvider), address(mockLendingProvider));
        assertEq(address(swapProvider), address(mockSwapProvider));
    }

    function test_SetRebalanceRules() public {
        this.doInitialize();
        RebalanceLimit memory rebalanceLimit = RebalanceLimit({
            minimalWBTCBalance: 1 * 1e8,
            minimalWETHBalance: 100 * 1e18,
            minimalStableCoinBalance: 100 * 1e6,
            minimalTimestampBetweenRebalances: 30,
            maxRebalancePercentage: 10
        });
        this.setRebalanceRules(rebalanceLimit);
        (
            uint256 minimalWBTCBalance,
            uint256 minimalWETHBalance,
            uint256 minimalStableCoinBalance,
            uint256 minimalTimestampBetweenRebalances,
            uint256 maxRebalancePercentage
        ) = this.rebalanceLimit();
        assertEq(minimalWBTCBalance, 1 * 1e8);
        assertEq(minimalWETHBalance, 100 * 1e18);
        assertEq(minimalStableCoinBalance, 100 * 1e6);
        assertEq(minimalTimestampBetweenRebalances, 30);
        assertEq(maxRebalancePercentage, 10);
    }

    function test_SupplyRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        this.supply(address(0), 1 ether);
    }

    function test_SupplyRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        this.supply(address(mockWETH), 0);
    }

    function test_WithdrawRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        this.withdraw(address(mockWETH), 0);
    }

    function test_WithdrawRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        this.withdraw(address(0), 1 ether);
    }

    function test_SwapRevertAmountIsZero() public {
        this.doInitialize();

        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = 0;

        vm.expectRevert(AmountIsZero.selector);
        this.swap(abi.encode(address(0), sellAmount, address(mockUSDT), buyAmountMin));
    }

    function test_SwapRevertInsufficientBalance() public {
        this.doInitialize();
        // Ensure test contract has no ETH balance
        vm.deal(address(this), 0);

        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = 1;

        vm.expectRevert(InsufficientBalance.selector);
        this.swap(abi.encode(address(0), sellAmount, address(mockUSDT), buyAmountMin));
    }

    function test_revertTurnETHToWETH() public {
        MockLendingProvider testLendingProvider = new MockLendingProvider();
        MockSwapProvider testSwapProvider = new MockSwapProvider();
        this.initialize(
            address(0),
            address(mockWBTC),
            address(mockUSDT),
            address(mockUSDC),
            address(testLendingProvider),
            address(testSwapProvider)
        );
        vm.expectRevert(WETHNotSet.selector);
        this.turnETHToWETH();
    }

    function test_revertGetWETHBalance() public {
        MockLendingProvider testLendingProvider = new MockLendingProvider();
        MockSwapProvider testSwapProvider = new MockSwapProvider();
        this.initialize(
            address(0),
            address(mockWBTC),
            address(mockUSDT),
            address(mockUSDC),
            address(testLendingProvider),
            address(testSwapProvider)
        );
        vm.expectRevert(WETHNotSet.selector);
        this.getWETHBalance();
    }

    function test_Supply() public {
        this.doInitialize();

        // Create mock token
        MockERC20 mockToken = new MockERC20("MockToken", "MTK", 18);

        uint256 supplyAmount = 1000 * 1e18;

        // Mint tokens to test contract
        deal(address(mockToken), address(this), supplyAmount);

        // Approve AssetManager to spend tokens (will be done by _supply)
        uint256 balanceBefore = mockLendingProvider.getBalance(address(mockToken));

        // Supply tokens
        this.supply(address(mockToken), supplyAmount);

        // Verify tokens were supplied
        uint256 balanceAfter = mockLendingProvider.getBalance(address(mockToken));
        assertEq(balanceAfter - balanceBefore, supplyAmount);

        // Verify test contract no longer has the tokens
        assertEq(mockToken.balanceOf(address(this)), 0);
    }

    function test_Withdraw() public {
        this.doInitialize();

        // Create mock token
        MockERC20 mockToken = new MockERC20("MockToken", "MTK", 18);
        uint256 supplyAmount = 1000 * 1e18;
        uint256 withdrawAmount = 500 * 1e18;

        // First, supply some tokens
        deal(address(mockToken), address(this), supplyAmount);
        this.supply(address(mockToken), supplyAmount);

        // Get balance before withdraw
        uint256 balanceBefore = mockToken.balanceOf(address(this));

        // Withdraw tokens
        this.withdraw(address(mockToken), withdrawAmount);

        // Verify tokens were withdrawn
        uint256 balanceAfter = mockToken.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, withdrawAmount);

        // Verify lending provider balance decreased
        assertEq(mockLendingProvider.getBalance(address(mockToken)), supplyAmount - withdrawAmount);
    }

    function test_SwapERC20ToERC20() public {
        this.doInitialize();

        // Create mock tokens
        MockERC20 sellToken = new MockERC20("SellToken", "STK", 18);
        MockERC20 buyToken = new MockERC20("BuyToken", "BTK", 18);

        // Set buy token as USDT asset for the test
        this.setAsset(AssetType.USDT, address(buyToken));

        uint256 sellAmount = 1000 * 1e18;
        uint256 buyAmount = 2000 * 1e18; // 1:2 exchange rate
        uint256 buyAmountMin = 1500 * 1e18;

        // Mint sell tokens to test contract
        deal(address(sellToken), address(this), sellAmount);

        // Approve swap provider to spend sell tokens
        sellToken.approve(address(mockSwapProvider), sellAmount);

        // Mint buy tokens to swap provider so it can return them
        deal(address(buyToken), address(mockSwapProvider), buyAmount);

        // Set swap mapping
        bytes memory swapData = abi.encode(address(sellToken), sellAmount, address(buyToken), buyAmount);

        // Get balances before swap
        uint256 sellBalanceBefore = sellToken.balanceOf(address(this));
        uint256 buyBalanceBefore = buyToken.balanceOf(address(this));

        // Perform swap
        this.swap(swapData);

        // Verify sell token balance decreased
        uint256 sellBalanceAfter = sellToken.balanceOf(address(this));
        assertEq(sellBalanceBefore - sellBalanceAfter, sellAmount);

        // Verify buy token balance increased (at least buyAmountMin)
        uint256 buyBalanceAfter = buyToken.balanceOf(address(this));
        assertGe(buyBalanceAfter - buyBalanceBefore, buyAmountMin);
    }

    function test_SwapETHToERC20() public {
        this.doInitialize();

        uint256 sellAmount = 1 ether;
        uint256 buyAmount = 2000 * 1e18; // 1 ETH = 2000 tokens
        uint256 buyAmountMin = 1500 * 1e18;

        // Give test contract ETH
        vm.deal(address(this), sellAmount);

        MockERC20 buyToken = new MockERC20("BuyToken", "BTK", 18);

        // Mint buy tokens to swap provider so it can return them
        deal(address(buyToken), address(mockSwapProvider), buyAmount);

        // Get balances before swap
        uint256 ethBalanceBefore = address(this).balance;
        uint256 buyBalanceBefore = buyToken.balanceOf(address(this));

        // Perform swap
        this.swap(abi.encode(address(0), sellAmount, address(buyToken), buyAmountMin));

        // Verify ETH balance decreased
        uint256 ethBalanceAfter = address(this).balance;
        assertEq(ethBalanceBefore - ethBalanceAfter, sellAmount);

        // Verify buy token balance increased (at least buyAmountMin)
        uint256 buyBalanceAfter = buyToken.balanceOf(address(this));
        assertGe(buyBalanceAfter - buyBalanceBefore, buyAmountMin);
    }

    function test_SwapERC20ToETH() public {
        this.doInitialize();

        // Create mock sell token
        MockERC20 sellToken = new MockERC20("SellToken", "STK", 18);

        uint256 sellAmount = 1000 * 1e18;
        uint256 buyAmount = 0.5 ether; // 1000 tokens = 0.5 ETH
        uint256 buyAmountMin = 0.4 ether;

        // Mint sell tokens to test contract
        deal(address(sellToken), address(this), sellAmount);

        // Approve swap provider to spend sell tokens
        sellToken.approve(address(mockSwapProvider), sellAmount);

        // Mint WETH to swap provider so it can return it
        deal(address(mockWETH), address(mockSwapProvider), buyAmount);

        // Get balances before swap
        uint256 sellBalanceBefore = sellToken.balanceOf(address(this));
        uint256 wethBalanceBefore = MockWETH(mockWETH).balanceOf(address(this));

        // Perform swap
        this.swap(abi.encode(address(sellToken), sellAmount, address(mockWETH), buyAmountMin));

        // Verify sell token balance decreased
        uint256 sellBalanceAfter = sellToken.balanceOf(address(this));
        assertEq(sellBalanceBefore - sellBalanceAfter, sellAmount);

        // Verify WETH balance increased (at least buyAmountMin)
        uint256 wethBalanceAfter = MockWETH(mockWETH).balanceOf(address(this));
        assertGe(wethBalanceAfter - wethBalanceBefore, buyAmountMin);
    }
}

