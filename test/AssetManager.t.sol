// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {AssetManager} from "../src/AssetManager.sol";
import {ITrust} from "../src/interfaces/ITrust.sol";
import {mainnet} from "../script/addresses.sol";
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
import {IPoolDataProvider} from "../src/libs/Aave.sol";

import {
    PoolKey,
    IPoolManager,
    PoolStateLibrary,
    BaseData,
    SwapFlags,
    PoolId,
    PoolIdLibrary
} from "../src/libs/Uniswap.sol";

import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract TestAssetManager is Test, AssetManager {
    using SafeERC20 for IERC20;
    using Address for address;
    using PoolStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function setRebalanceRules(RebalanceLimit memory rebalanceLimit) external {
        _setRebalanceRules(rebalanceLimit);
    }

    function turnETHToWETH() external {
        _turnETHToWETH();
    }

    function swap(
        address sellAssetAddress,
        uint256 sellAmount,
        AssetType toAssetType,
        uint256 buyAmountMin,
        bytes memory data
    ) external {
        _swap(sellAssetAddress, sellAmount, toAssetType, buyAmountMin, data);
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
        address aaveV3Address,
        address uniswapV4RouterAddress
    ) public initializer {
        _initialize(wethAddress, wbtcAddress, usdtAddress, usdcAddress, aaveV3Address, uniswapV4RouterAddress);
    }

    function setUp() public {}

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
        this.swap(address(0), 1 ether, AssetType.USDT, 1 ether, "");
        vm.expectRevert(NotInitialized.selector);
        this.rebalance(AssetType.USDT, AssetType.USDC, 1 ether, 1 ether, "");
    }

    function doInitialize() public {
        this.initialize(
            address(mainnet.WETH),
            address(mainnet.WBTC),
            address(mainnet.USDT),
            address(mainnet.USDC),
            address(mainnet.AAVE_V3),
            address(mainnet.UNISWAP_V4_ROUTER)
        );
    }

    function test_InitializeWithAddressZero() public {
        uint256 snapshot = vm.snapshot();
        this.initialize(
            address(0),
            address(mainnet.WBTC),
            address(mainnet.USDT),
            address(mainnet.USDC),
            address(mainnet.AAVE_V3),
            address(mainnet.UNISWAP_V4_ROUTER)
        );
        assertEq(assets[AssetType.WETH], address(0));
        assertEq(assets[AssetType.WBTC], address(mainnet.WBTC));
        assertEq(assets[AssetType.USDT], address(mainnet.USDT));
        assertEq(assets[AssetType.USDC], address(mainnet.USDC));
        assertEq(address(aave), address(mainnet.AAVE_V3));
        assertEq(address(uniswapV4Router), address(mainnet.UNISWAP_V4_ROUTER));
        vm.revertTo(snapshot);
        this.initialize(
            address(mainnet.WETH),
            address(0),
            address(mainnet.USDT),
            address(mainnet.USDC),
            address(mainnet.AAVE_V3),
            address(mainnet.UNISWAP_V4_ROUTER)
        );
        assertEq(assets[AssetType.WETH], address(mainnet.WETH));
        assertEq(assets[AssetType.WBTC], address(0));
        assertEq(assets[AssetType.USDT], address(mainnet.USDT));
        assertEq(assets[AssetType.USDC], address(mainnet.USDC));
        assertEq(address(aave), address(mainnet.AAVE_V3));
        assertEq(address(uniswapV4Router), address(mainnet.UNISWAP_V4_ROUTER));
        vm.revertTo(snapshot);
        this.initialize(
            address(mainnet.WETH),
            address(mainnet.WBTC),
            address(0),
            address(mainnet.USDC),
            address(mainnet.AAVE_V3),
            address(mainnet.UNISWAP_V4_ROUTER)
        );
        assertEq(assets[AssetType.WETH], address(mainnet.WETH));
        assertEq(assets[AssetType.WBTC], address(mainnet.WBTC));
        assertEq(assets[AssetType.USDT], address(0));
        assertEq(assets[AssetType.USDC], address(mainnet.USDC));
        assertEq(address(aave), address(mainnet.AAVE_V3));
        assertEq(address(uniswapV4Router), address(mainnet.UNISWAP_V4_ROUTER));
        vm.revertTo(snapshot);
        this.initialize(
            address(mainnet.WETH),
            address(mainnet.WBTC),
            address(mainnet.USDT),
            address(0),
            address(mainnet.AAVE_V3),
            address(mainnet.UNISWAP_V4_ROUTER)
        );
        assertEq(assets[AssetType.WETH], address(mainnet.WETH));
        assertEq(assets[AssetType.WBTC], address(mainnet.WBTC));
        assertEq(assets[AssetType.USDT], address(mainnet.USDT));
        assertEq(assets[AssetType.USDC], address(0));
        assertEq(address(aave), address(mainnet.AAVE_V3));
        assertEq(address(uniswapV4Router), address(mainnet.UNISWAP_V4_ROUTER));
        vm.revertTo(snapshot);
        this.initialize(
            address(mainnet.WETH),
            address(mainnet.WBTC),
            address(mainnet.USDT),
            address(mainnet.USDC),
            address(0),
            address(mainnet.UNISWAP_V4_ROUTER)
        );
        assertEq(assets[AssetType.WETH], address(mainnet.WETH));
        assertEq(assets[AssetType.WBTC], address(mainnet.WBTC));
        assertEq(assets[AssetType.USDT], address(mainnet.USDT));
        assertEq(assets[AssetType.USDC], address(mainnet.USDC));
        assertEq(address(aave), address(0));
        assertEq(address(uniswapV4Router), address(mainnet.UNISWAP_V4_ROUTER));
        vm.revertTo(snapshot);
        this.initialize(
            address(mainnet.WETH),
            address(mainnet.WBTC),
            address(mainnet.USDT),
            address(mainnet.USDC),
            address(mainnet.AAVE_V3),
            address(0)
        );
        assertEq(assets[AssetType.WETH], address(mainnet.WETH));
        assertEq(assets[AssetType.WBTC], address(mainnet.WBTC));
        assertEq(assets[AssetType.USDT], address(mainnet.USDT));
        assertEq(assets[AssetType.USDC], address(mainnet.USDC));
        assertEq(address(aave), address(mainnet.AAVE_V3));
        assertEq(address(uniswapV4Router), address(0));
    }

    function test_Initialize() public {
        this.doInitialize();
        assertEq(assets[AssetType.WETH], address(mainnet.WETH));
        assertEq(assets[AssetType.WBTC], address(mainnet.WBTC));
        assertEq(assets[AssetType.USDT], address(mainnet.USDT));
        assertEq(assets[AssetType.USDC], address(mainnet.USDC));
        assertEq(address(aave), address(mainnet.AAVE_V3));
        assertEq(address(uniswapV4Router), address(mainnet.UNISWAP_V4_ROUTER));
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
        this.supply(address(mainnet.WETH), 0);
    }

    function test_WithdrawRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        this.withdraw(mainnet.WETH, 0);
    }

    function test_WithdrawRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        this.withdraw(address(0), 1 ether);
    }

    function test_SwapRevertAmountIsZero() public {
        this.doInitialize();
        PoolKey memory poolKey = PoolKey({
            currency0: address(0), currency1: address(mainnet.USDT), fee: 3000, tickSpacing: 60, hooks: address(0)
        });

        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = 0;

        BaseData memory baseData = BaseData({
            amount: sellAmount,
            amountLimit: sellAmount,
            payer: address(this),
            receiver: address(this),
            flags: SwapFlags.SINGLE_SWAP
        });

        bytes memory swapData = abi.encode(baseData, true, poolKey, "");
        vm.expectRevert(AmountIsZero.selector);
        this.swap(address(0), sellAmount, AssetType.USDT, buyAmountMin, swapData);
    }

    function test_SwapRevertInsufficientBalance() public {
        this.doInitialize();
        // Ensure test contract has no ETH balance
        vm.deal(address(this), 0);

        PoolKey memory poolKey = PoolKey({
            currency0: address(0), currency1: address(mainnet.USDT), fee: 3000, tickSpacing: 60, hooks: address(0)
        });

        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = 1;

        BaseData memory baseData = BaseData({
            amount: sellAmount,
            amountLimit: buyAmountMin,
            payer: address(this),
            receiver: address(this),
            flags: SwapFlags.SINGLE_SWAP
        });

        bytes memory swapData = abi.encode(baseData, true, poolKey, "");
        vm.expectRevert(InsufficientBalance.selector);
        this.swap(address(0), sellAmount, AssetType.USDT, buyAmountMin, swapData);
    }

    function test_revertTurnETHToWETH() public {
        this.initialize(
            address(0),
            address(mainnet.WBTC),
            address(mainnet.USDT),
            address(mainnet.USDC),
            address(mainnet.AAVE_V3),
            address(mainnet.UNISWAP_V4_ROUTER)
        );
        vm.expectRevert(WETHNotSet.selector);
        this.turnETHToWETH();
    }

    function test_revertGetWETHBalance() public {
        this.initialize(
            address(0),
            address(mainnet.WBTC),
            address(mainnet.USDT),
            address(mainnet.USDC),
            address(mainnet.AAVE_V3),
            address(mainnet.UNISWAP_V4_ROUTER)
        );
        vm.expectRevert(WETHNotSet.selector);
        this.getWETHBalance();
    }
}
