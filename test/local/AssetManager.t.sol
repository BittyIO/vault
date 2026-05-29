// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {AmountIsZero, AddressZero, SubscriptionNotFound} from "../../src/interfaces/IVault.sol";
import {
    InvalidLendingProvider,
    InvalidStakingProvider,
    RebalanceMaxAmount,
    RebalanceDisabled,
    RebalanceInMinimalTime,
    MinimalBalanceNotMet,
    DisableRebalanceUntilTimestampTooEarly,
    OnlyAssetManager,
    OnlyOwnerOrAssetManager,
    ETHBalanceNotEnough
} from "../../src/interfaces/IAssetManager.sol";
import {Subscription} from "subscription-contracts/src/Subscription.sol";
import {SubscriptionTestSetup} from "../helpers/SubscriptionTestSetup.sol";
import {Deprecated, NotWhiteListed} from "whitelist-contracts/src/interfaces/IWhiteList.sol";
import {ILendingProvider} from "provider-contracts/src/interfaces/ILendingProvider.sol";
import {IStakingProvider} from "provider-contracts/src/interfaces/IStakingProvider.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {mainnet} from "provider-contracts/script/addresses.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {WhiteList} from "whitelist-contracts/src/WhiteList.sol";
import {Vault} from "../../src/Vault.sol";
import {AssetManagerLogic} from "../../src/logic/AssetManagerLogic.sol";
import {AddingAssetsDisabled} from "../../src/interfaces/IVault.sol";
import {ProviderTestSetup} from "../helpers/ProviderTestSetup.sol";
import {AaveV3Provider} from "provider-contracts/src/providers/AaveV3Provider.sol";

contract TestAssetManager is ProviderTestSetup, Vault {
    address public whiteListAddress;
    address public subscriptionAddress;
    address[] public assets;
    address[] public stableCoins;
    address[] public lendingProviders;
    address[] public stakingProviders;
    address[] public ammProviders;
    address public assetManagerAddress;
    address public ownerAddress;

    function setUp() public {
        ownerAddress = tx.origin;
        assetManagerAddress = makeAddr("assetManager");

        WhiteList whiteList = new WhiteList();
        whiteListAddress = address(whiteList);
        subscriptionAddress = address(deploySubscription(whiteListAddress));

        vm.startPrank(tx.origin);
        whiteList.grantRole(whiteList.ASSET_MANAGER_ROLE(), tx.origin);
        whiteList.grantRole(whiteList.STABLE_COIN_MANAGER_ROLE(), tx.origin);
        whiteList.grantRole(whiteList.LENDING_MANAGER_ROLE(), tx.origin);
        whiteList.grantRole(whiteList.STAKING_MANAGER_ROLE(), tx.origin);
        whiteList.grantRole(whiteList.AMM_MANAGER_ROLE(), tx.origin);
        whiteList.addAssets(_two(mainnet.WETH, WBTC));
        whiteList.addStableCoins(_two(mainnet.USDT, mainnet.USDC));
        vm.stopPrank();

        setupMainnetForkProviders(whiteList);

        assets = _two(mainnet.WETH, WBTC);
        stableCoins = _two(mainnet.USDT, mainnet.USDC);
        lendingProviders = _single(address(aaveProvider));
        stakingProviders = _single(address(lidoProvider));
        ammProviders = _single(address(uniswapV3Provider));
    }

    function _two(address a, address b) private pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function getClonedProvider(address provider) external view returns (address) {
        return _assetManager.clonedProviders[provider];
    }

    function cloneProviderForTesting(address provider) external returns (address) {
        return AssetManagerLogic.cloneProvider(_assetManager, provider);
    }

    function doInitialize() public {
        this.initialize(
            whiteListAddress,
            subscriptionAddress,
            mainnet.WETH,
            assets,
            stableCoins,
            lendingProviders,
            stakingProviders,
            ammProviders
        );
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress);
        _subscribeForAssetManagerOps();
    }

    function _subscribeForAssetManagerOps() internal {
        Subscription subscription = Subscription(subscriptionAddress);
        subscribeUser(subscription, assetManagerAddress, mainnet.USDC, 1);
        subscribeUser(subscription, ownerAddress, mainnet.USDC, 1);
    }

    function _subscribeUser(address user) internal {
        subscribeUser(Subscription(subscriptionAddress), user, mainnet.USDC, 1);
    }

    function doInitializeWithoutSubscription() public {
        this.initialize(
            whiteListAddress,
            subscriptionAddress,
            mainnet.WETH,
            assets,
            stableCoins,
            lendingProviders,
            stakingProviders,
            ammProviders
        );
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress);
    }

    function test_SetRebalanceConfig() public {
        this.doInitialize();
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: 100 * 1e6, minimalDuration: 30, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(mainnet.WETH, rebalanceConfig);
    }

    function test_Supply_revertSubscriptionNotFound() public {
        this.doInitializeWithoutSubscription();

        vm.prank(assetManagerAddress);
        vm.expectRevert(SubscriptionNotFound.selector);
        this.supply(address(aaveProvider), address(mainnet.WETH), 1 ether);
    }

    function test_RevertOnlyAssetManager() public {
        this.doInitialize();
        address subscribedStranger = makeAddr("subscribedStranger");
        _subscribeUser(subscribedStranger);

        vm.prank(subscribedStranger);
        vm.expectRevert(OnlyAssetManager.selector);
        this.supply(address(aaveProvider), address(mainnet.WETH), 1 ether);
        vm.prank(subscribedStranger);
        vm.expectRevert(OnlyAssetManager.selector);
        this.withdraw(address(aaveProvider), address(mainnet.WETH), 1 ether);
        vm.prank(subscribedStranger);
        vm.expectRevert(OnlyAssetManager.selector);
        this.rebalance(address(uniswapV3Provider), address(WBTC), address(mainnet.USDT), 1 ether, 1 ether, "");
    }

    function test_SupplyRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProvider), address(0), 1 ether);
    }

    function test_SupplyRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProvider), address(mainnet.WETH), 0);
    }

    function test_WithdrawRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProvider), address(mainnet.WETH), 0);
    }

    function test_WithdrawRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProvider), address(0), 1 ether);
    }

    function test_revertETHToWETH() public {
        this.doInitialize();
        vm.expectRevert(OnlyOwnerOrAssetManager.selector);
        this.ETHToWETH(1 ether);
    }

    function test_ETHToWETHSuccess() public {
        this.doInitialize();
        uint256 wethBefore = IERC20(mainnet.WETH).balanceOf(address(this));
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);
        vm.prank(assetManagerAddress);
        this.ETHToWETH(amount);
        assertApproxEqAbs(IERC20(mainnet.WETH).balanceOf(address(this)) - wethBefore, amount, 10);
    }

    /// @dev Regression: plain ETH sends must not revert (Vault.receive). Matches wallet "Send ETH" (empty calldata).
    function test_ethDeposit_viaReceive_thenETHToWETH() public {
        this.doInitialize();

        uint256 amount = 0.1 ether;
        address depositor = makeAddr("ethDepositor");
        uint256 ethBefore = address(this).balance;
        uint256 wethBefore = IERC20(mainnet.WETH).balanceOf(address(this));

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success, bytes memory returnData) = address(this).call{value: amount}("");

        assertTrue(success, string(returnData));
        assertEq(address(this).balance - ethBefore, amount);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), wethBefore);

        uint256 ethAfterDeposit = address(this).balance;
        vm.prank(assetManagerAddress);
        this.ETHToWETH(amount);

        assertEq(address(this).balance, ethAfterDeposit - amount);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), wethBefore + amount);
    }

    function test_ETHToWETH_revertsWhenEthBalanceInsufficient() public {
        this.doInitialize();

        vm.deal(address(this), 0.5 ether);

        vm.prank(assetManagerAddress);
        vm.expectRevert(ETHBalanceNotEnough.selector);
        this.ETHToWETH(1 ether);
    }

    function test_SupplyRevertInvalidLendingProvider() public {
        this.doInitialize();
        address invalidLendingProvider = address(new AaveV3Provider(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER));
        vm.expectRevert(InvalidLendingProvider.selector);
        vm.prank(assetManagerAddress);
        this.supply(invalidLendingProvider, address(mainnet.WETH), 1 ether);
    }

    function test_SupplySuccess() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProvider), mainnet.WETH, supplyAmount);

        address clonedProvider = this.getClonedProvider(address(aaveProvider));
        require(clonedProvider != address(0), "Provider should be cloned");

        uint256 balanceAfter = ILendingProvider(clonedProvider).getSuppliedBalance(mainnet.WETH);
        assertApproxEqAbs(balanceAfter, supplyAmount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_WithdrawSuccess() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        uint256 withdrawAmount = 0.5 ether;

        deal(mainnet.WETH, address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProvider), mainnet.WETH, supplyAmount);

        address clonedProvider = this.getClonedProvider(address(aaveProvider));
        uint256 balanceBefore = IERC20(mainnet.WETH).balanceOf(address(this));

        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProvider), mainnet.WETH, withdrawAmount);

        uint256 balanceAfter = IERC20(mainnet.WETH).balanceOf(address(this));
        assertApproxEqAbs(balanceAfter - balanceBefore, withdrawAmount, 5);

        uint256 remaining = ILendingProvider(clonedProvider).getSuppliedBalance(mainnet.WETH);
        assertApproxEqAbs(remaining, supplyAmount - withdrawAmount, 10);
    }

    function test_LendingProviderRevertIfNotWhiteListed() public {
        this.doInitialize();

        address invalidLendingProvider = makeAddr("InvalidLendingProvider");
        vm.expectRevert(InvalidLendingProvider.selector);
        vm.prank(assetManagerAddress);
        this.supply(invalidLendingProvider, address(mainnet.WETH), 1 ether);
    }

    function test_SupplyFromDeprecatedLendingProvider() public {
        this.doInitialize();
        vm.prank(tx.origin);
        WhiteList(whiteListAddress).deprecateLendingProviders(lendingProviders);
        vm.expectRevert(Deprecated.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProvider), address(mainnet.WETH), 1 ether);
    }

    function test_WithdrawMoneySuccessFromDeprecateLendingProvider() public {
        this.doInitialize();
        deal(address(mainnet.WETH), address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProvider), address(mainnet.WETH), 1 ether);
        vm.prank(tx.origin);
        WhiteList(whiteListAddress).deprecateLendingProviders(lendingProviders);
        uint256 supplied = this.getSuppliedBalance(address(aaveProvider), address(mainnet.WETH));
        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProvider), address(mainnet.WETH), supplied);
    }

    function test_WithdrawFromInvalidLendingProvider() public {
        this.doInitialize();
        address invalidLendingProvider = makeAddr("InvalidLendingProvider");
        vm.expectRevert(InvalidLendingProvider.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(invalidLendingProvider, address(mainnet.WETH), 1 ether);
    }

    function test_GetBalance() public {
        this.doInitialize();
        uint256 depositAmount = 5 ether;

        uint256 balance = this.getSuppliedBalance(address(aaveProvider), address(mainnet.WETH));
        assertEq(balance, 0);

        deal(address(mainnet.WETH), address(this), depositAmount);
        IERC20(mainnet.WETH).approve(address(this), depositAmount);

        vm.prank(assetManagerAddress);
        this.supply(address(aaveProvider), address(mainnet.WETH), depositAmount);

        balance = this.getSuppliedBalance(address(aaveProvider), address(mainnet.WETH));
        assertApproxEqAbs(balance, depositAmount, 10);
    }

    function test_GetBalance_InvalidLendingProvider() public {
        this.doInitialize();
        address invalidLendingProvider = makeAddr("InvalidLendingProvider");

        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidLendingProvider.selector);
        this.getSuppliedBalance(invalidLendingProvider, address(mainnet.WETH));
    }

    function test_GetBalanceFromDeprecatedLendingProvider() public {
        this.doInitialize();
        vm.prank(tx.origin);
        WhiteList(whiteListAddress).deprecateLendingProviders(lendingProviders);
        uint256 balance = this.getSuppliedBalance(address(aaveProvider), address(mainnet.WETH));
        assertEq(balance, 0);
    }

    function test_RebalanceMaxAmount_ExceedsRebalanceConfig() public {
        this.doInitialize();
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: 0, minimalDuration: 7 days, maxAmount: 999});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(mainnet.WETH, rebalanceConfig);
        uint256 fromBalance = 1000 * 1e18;
        uint256 sellAmount = 100 * 1e18;

        deal(address(mainnet.WETH), address(this), fromBalance);
        IERC20(mainnet.WETH).approve(address(this), sellAmount);

        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mainnet.WETH), sellAmount, address(mainnet.USDT), buyAmount);

        vm.expectRevert(RebalanceMaxAmount.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(
            address(uniswapV3Provider), address(mainnet.WETH), address(mainnet.USDT), sellAmount, buyAmount, swapData
        );
    }

    function test_RebalanceMaxAmount_WithinLimit() public {
        this.doInitialize();

        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 1000});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(mainnet.WETH, rebalanceConfig);

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), sellAmount);
        uint256 buyAmountMin = 1;
        bytes memory swapData = encodeWethToUsdtSwap(sellAmount, buyAmountMin);
        uint256 usdtBefore = IERC20(mainnet.USDT).balanceOf(address(this));

        vm.prank(assetManagerAddress);
        this.rebalance(address(uniswapV3Provider), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);

        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
        assertGt(IERC20(mainnet.USDT).balanceOf(address(this)), usdtBefore);
    }

    function test_RebalanceMaxAmount_ZeroSkipsCheck() public {
        this.doInitialize();

        RebalanceConfig memory rebalanceConfig = RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(mainnet.WETH, rebalanceConfig);

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), sellAmount);
        uint256 buyAmountMin = 1;
        bytes memory swapData = encodeWethToUsdtSwap(sellAmount, buyAmountMin);

        vm.prank(assetManagerAddress);
        this.rebalance(address(uniswapV3Provider), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);
    }

    function test_RebalanceFromCheck_RevertsWhenFromNotVaultAsset() public {
        this.doInitialize();

        RebalanceConfig memory rebalanceConfig = RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mainnet.USDT), rebalanceConfig);

        address invalidFrom = makeAddr("invalidFromAsset");
        uint256 sellAmount = 1 ether;
        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(invalidFrom, sellAmount, address(mainnet.USDT), buyAmount);

        vm.expectRevert(NotWhiteListed.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(address(uniswapV3Provider), invalidFrom, address(mainnet.USDT), sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFromCheck_MinimalBalanceNotMet_WhenRemainingBelowMinimal() public {
        this.doInitialize();

        uint256 minimalBalance = 100 ether;
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: minimalBalance, minimalDuration: 1, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(mainnet.WETH, rebalanceConfig);

        uint256 fromBalance = 1000 ether;
        uint256 sellAmount = 950 ether;

        deal(address(mainnet.WETH), address(this), fromBalance);
        IERC20(mainnet.WETH).approve(address(this), fromBalance);

        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mainnet.WETH), sellAmount, address(mainnet.USDT), buyAmount);

        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(
            address(uniswapV3Provider), address(mainnet.WETH), address(mainnet.USDT), sellAmount, buyAmount, swapData
        );
    }

    function test_RebalanceFromCheck_MinimalBalanceNotMet_WhenSellExceedsBalance() public {
        this.doInitialize();

        uint256 minimalBalance = 100 ether;
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: minimalBalance, minimalDuration: 1, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(mainnet.WETH, rebalanceConfig);

        uint256 fromBalance = 50 ether;
        uint256 sellAmount = 100 ether;

        deal(address(mainnet.WETH), address(this), fromBalance);
        IERC20(mainnet.WETH).approve(address(this), fromBalance);

        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mainnet.WETH), sellAmount, address(mainnet.USDT), buyAmount);

        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(
            address(uniswapV3Provider), address(mainnet.WETH), address(mainnet.USDT), sellAmount, buyAmount, swapData
        );
    }

    function test_RebalanceFromCheck_MinimalBalance_SucceedsWhenRemainingAtLeastMinimal() public {
        this.doInitialize();

        uint256 minimalBalance = 4 ether;
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: minimalBalance, minimalDuration: 1, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(mainnet.WETH, rebalanceConfig);

        uint256 fromBalance = 10 ether;
        uint256 sellAmount = 5 ether;

        deal(mainnet.WETH, address(this), fromBalance);
        uint256 buyAmountMin = 1;
        bytes memory swapData = encodeWethToUsdtSwap(sellAmount, buyAmountMin);

        vm.prank(assetManagerAddress);
        this.rebalance(address(uniswapV3Provider), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);

        assertApproxEqAbs(IERC20(mainnet.WETH).balanceOf(address(this)), fromBalance - sellAmount, 10);
    }

    function test_RebalanceFromCheck_RebalanceInMinimalTime_RevertsWhenFromDurationNotElapsed() public {
        this.doInitialize();

        uint256 minimalDuration = 7 days;
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: 0, minimalDuration: minimalDuration, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(mainnet.WETH, rebalanceConfig);

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), 1 ether);
        uint256 buyAmountMin = 1;
        bytes memory swapData = encodeWethToUsdtSwap(sellAmount, buyAmountMin);

        vm.prank(assetManagerAddress);
        this.rebalance(address(uniswapV3Provider), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);

        vm.expectRevert(RebalanceInMinimalTime.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(address(uniswapV3Provider), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);
    }

    function test_RebalanceFromCheck_RebalanceInMinimalTime_SucceedsAfterFromDurationElapsed() public {
        this.doInitialize();

        uint256 minimalDuration = 7 days;
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: 0, minimalDuration: minimalDuration, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(mainnet.WETH, rebalanceConfig);

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), 1 ether);
        uint256 buyAmountMin = 1;
        bytes memory swapData = encodeWethToUsdtSwap(sellAmount, buyAmountMin);

        vm.prank(assetManagerAddress);
        this.rebalance(address(uniswapV3Provider), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);

        vm.warp(block.timestamp + minimalDuration + 1);

        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.rebalance(address(uniswapV3Provider), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_RevertsWhenBeforeTimestamp() public {
        this.doInitialize();
        RebalanceConfig memory rebalanceConfig = RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(mainnet.WETH, rebalanceConfig);

        uint256 disabledUntil = block.timestamp + 100;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(disabledUntil);

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), sellAmount);
        uint256 buyAmountMin = 1;
        bytes memory swapData = encodeWethToUsdtSwap(sellAmount, buyAmountMin);

        vm.expectRevert(RebalanceDisabled.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(address(uniswapV3Provider), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_SucceedsAfterTimestamp() public {
        this.doInitialize();
        RebalanceConfig memory rebalanceConfig = RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(mainnet.WETH, rebalanceConfig);

        uint256 disabledUntil = block.timestamp + 100;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(disabledUntil);

        vm.warp(disabledUntil + 1);

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), sellAmount);
        uint256 buyAmountMin = 1;
        bytes memory swapData = encodeWethToUsdtSwap(sellAmount, buyAmountMin);

        vm.prank(assetManagerAddress);
        this.rebalance(address(uniswapV3Provider), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);

        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_SucceedsWhenNeverDisabled() public {
        this.doInitialize();
        RebalanceConfig memory rebalanceConfig = RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(mainnet.WETH, rebalanceConfig);

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), sellAmount);
        uint256 buyAmountMin = 1;
        bytes memory swapData = encodeWethToUsdtSwap(sellAmount, buyAmountMin);

        vm.prank(assetManagerAddress);
        this.rebalance(address(uniswapV3Provider), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);

        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_DisableRebalanceUntilTimestampTooEarly_RevertsWhenNewTimestampEarlier() public {
        this.doInitialize();

        uint256 firstDisabledUntil = block.timestamp + 200;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(firstDisabledUntil);

        uint256 earlierTimestamp = block.timestamp + 100;
        vm.expectRevert(DisableRebalanceUntilTimestampTooEarly.selector);
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(earlierTimestamp);
    }

    function test_DisableAddingAssets_RevertsWhenNotOwnerOrAssetManager() public {
        this.doInitialize();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(OnlyOwnerOrAssetManager.selector);
        this.disableAddingAssets();
    }

    function test_DisableAddingAssets_SucceedsAndAddAssetsReverts() public {
        this.doInitialize();

        MockERC20 mockDAI = new MockERC20("DAI", "DAI", 18);
        address[] memory newAssets = new address[](1);
        newAssets[0] = address(mockDAI);
        vm.prank(ownerAddress);
        WhiteList(whiteListAddress).addAssets(newAssets);

        vm.prank(ownerAddress);
        this.disableAddingAssets();

        vm.expectRevert(AddingAssetsDisabled.selector);
        vm.prank(ownerAddress);
        this.addAssets(newAssets);
    }

    function test_StakeRevertOnlyAssetManager() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        address subscribedStranger = makeAddr("subscribedStranger");
        _subscribeUser(subscribedStranger);
        vm.prank(subscribedStranger);
        vm.expectRevert(OnlyAssetManager.selector);
        this.stake(address(lidoProvider), mainnet.WETH, 1 ether);
    }

    function test_StakeRevertInvalidStakingProvider() public {
        this.doInitialize();
        address invalidStakingProvider = makeAddr("InvalidStakingProvider");
        vm.expectRevert(InvalidStakingProvider.selector);
        vm.prank(assetManagerAddress);
        this.stake(invalidStakingProvider, mainnet.WETH, 1 ether);
    }

    function test_StakeRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProvider), mainnet.WETH, 0);
    }

    function test_StakeSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        assertEq(this.getStakedBalance(address(lidoProvider), mainnet.WETH), 0);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProvider), mainnet.WETH, stakeAmount);

        address clonedProvider = this.getClonedProvider(address(lidoProvider));
        assertTrue(clonedProvider != address(0));
        assertApproxEqAbs(IStakingProvider(clonedProvider).getStakedBalance(mainnet.WETH), stakeAmount, 10);
        assertApproxEqAbs(this.getStakedBalance(address(lidoProvider), mainnet.WETH), stakeAmount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_GetStakingBalance() public {
        this.doInitialize();
        assertEq(this.getStakedBalance(address(lidoProvider), mainnet.WETH), 0);

        uint256 stakeAmount = 2 ether;
        deal(mainnet.WETH, address(this), stakeAmount);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProvider), mainnet.WETH, stakeAmount);

        assertApproxEqAbs(this.getStakedBalance(address(lidoProvider), mainnet.WETH), stakeAmount, 10);
    }

    function test_GetStakingBalance_InvalidStakingProvider() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProvider.selector);
        this.getStakedBalance(makeAddr("InvalidStakingProvider"), mainnet.WETH);
    }

    function test_UnstakeSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 1 ether;
        uint256 unstakeAmount = 0.5 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProvider), mainnet.WETH, stakeAmount);
        assertApproxEqAbs(this.getStakedBalance(address(lidoProvider), mainnet.WETH), stakeAmount, 10);

        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProvider), mainnet.WETH, unstakeAmount);
        assertApproxEqAbs(this.getStakedBalance(address(lidoProvider), mainnet.WETH), stakeAmount - unstakeAmount, 10);

        uint256[] memory requestIds = this.getUnstakeRequestIds(address(lidoProvider));
        assertEq(requestIds.length, 1);

        vm.prank(assetManagerAddress);
        this.claimUnstaked(address(lidoProvider), requestIds);
    }

    function test_ClaimSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 0.1 ether;
        uint256 unstakeAmount = 0.05 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProvider), mainnet.WETH, stakeAmount);
        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProvider), mainnet.WETH, unstakeAmount);

        uint256[] memory requestIds = this.getUnstakeRequestIds(address(lidoProvider));
        assertEq(requestIds.length, 1);

        vm.prank(assetManagerAddress);
        this.claimUnstaked(address(lidoProvider), requestIds);
        // Lido withdrawals are not finalized immediately on a mainnet fork.
        assertEq(this.getUnstakeRequestIds(address(lidoProvider)).length, 1);
    }

    function test_ClaimRevertOnlyAssetManager() public {
        this.doInitialize();
        uint256[] memory requestIds = new uint256[](0);
        address subscribedStranger = makeAddr("subscribedStranger");
        _subscribeUser(subscribedStranger);
        vm.prank(subscribedStranger);
        vm.expectRevert(OnlyAssetManager.selector);
        this.claimUnstaked(address(lidoProvider), requestIds);
    }

    function test_ClaimRevertInvalidStakingProvider() public {
        this.doInitialize();
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = 1;
        vm.expectRevert(InvalidStakingProvider.selector);
        vm.prank(assetManagerAddress);
        this.claimUnstaked(makeAddr("InvalidStakingProvider"), requestIds);
    }

    function test_ClaimEmptyRequestIds_doesNotRevert() public {
        this.doInitialize();
        uint256[] memory requestIds = new uint256[](0);
        vm.prank(assetManagerAddress);
        this.claimUnstaked(address(lidoProvider), requestIds);
    }

    function test_UnstakeRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProvider), mainnet.WETH, 0);
    }

    function test_UnstakeRevertInvalidStakingProvider() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProvider.selector);
        vm.prank(assetManagerAddress);
        this.unstake(makeAddr("InvalidStakingProvider"), mainnet.WETH, 1 ether);
    }

    function test_GetUnstakeRequestIds() public {
        this.doInitialize();
        uint256[] memory ids = this.getUnstakeRequestIds(address(lidoProvider));
        assertEq(ids.length, 0);

        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProvider), mainnet.WETH, 1 ether);
        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProvider), mainnet.WETH, 0.5 ether);

        ids = this.getUnstakeRequestIds(address(lidoProvider));
        assertEq(ids.length, 1);
    }

    function test_GetUnstakeRequestIds_InvalidStakingProvider() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProvider.selector);
        this.getUnstakeRequestIds(makeAddr("InvalidStakingProvider"));
    }

    function test_SupplyAllowanceIsZeroAfterSuccess() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount);

        vm.prank(assetManagerAddress);
        this.supply(address(aaveProvider), mainnet.WETH, supplyAmount);

        address clonedProvider = this.getClonedProvider(address(aaveProvider));
        assertEq(IERC20(mainnet.WETH).allowance(address(this), clonedProvider), 0, "Allowance should be 0 after supply");
    }

    function test_SupplySucceedsWithPreExistingResidualAllowance() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount);

        address clonedProvider = this.cloneProviderForTesting(address(aaveProvider));

        IERC20(mainnet.WETH).approve(clonedProvider, 1);
        assertEq(IERC20(mainnet.WETH).allowance(address(this), clonedProvider), 1);

        vm.prank(assetManagerAddress);
        this.supply(address(aaveProvider), mainnet.WETH, supplyAmount);

        assertEq(IERC20(mainnet.WETH).allowance(address(this), clonedProvider), 0);
        assertApproxEqAbs(ILendingProvider(clonedProvider).getSuppliedBalance(mainnet.WETH), supplyAmount, 10);
    }

    function test_StakeSucceedsWithPreExistingResidualAllowance() public {
        this.doInitialize();

        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        address clonedProvider = this.cloneProviderForTesting(address(lidoProvider));

        IERC20(mainnet.WETH).approve(clonedProvider, 1);
        assertEq(IERC20(mainnet.WETH).allowance(address(this), clonedProvider), 1);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProvider), mainnet.WETH, stakeAmount);

        assertEq(IERC20(mainnet.WETH).allowance(address(this), clonedProvider), 0);
        assertApproxEqAbs(IStakingProvider(clonedProvider).getStakedBalance(mainnet.WETH), stakeAmount, 10);
    }
}
