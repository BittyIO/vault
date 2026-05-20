// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {AmountIsZero, AddressZero, ETHBalanceNotEnough} from "../../src/interfaces/IVault.sol";
import {
    InvalidLendingProvider,
    InvalidStakingProvider,
    RebalanceMaxAmount,
    RebalanceDisabled,
    RebalanceInMinimalTime,
    MinimalBalanceNotMet,
    DisableRebalanceUntilTimestampTooEarly,
    OnlyAssetManager
} from "../../src/interfaces/IAssetManager.sol";
import {Deprecated, NotWhiteListed} from "whitelist-contracts/src/interfaces/IWhiteList.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockLendingProvider} from "../mock/MockLendingProvider.sol";
import {MockStakingProvider} from "../mock/MockStakingProvider.sol";
import {MockAMMProvider} from "../mock/MockAMMProvider.sol";
import {WhiteList} from "whitelist-contracts/src/WhiteList.sol";
import {Vault} from "../../src/Vault.sol";
import {AssetManagerLogic} from "../../src/logic/AssetManagerLogic.sol";
import {AddingAssetsDisabled} from "../../src/interfaces/IVault.sol";

contract TestAssetManager is Test, Vault {
    address public mockWETH;
    address public mockWBTC;
    address public mockUSDT;
    address public mockUSDC;
    MockLendingProvider public mockLendingProvider;
    MockStakingProvider public mockStakingProvider;
    MockAMMProvider public mockAMMProvider;
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
        lendingProviders = new address[](1);
        mockLendingProvider = new MockLendingProvider();
        lendingProviders[0] = address(mockLendingProvider);

        mockStakingProvider = new MockStakingProvider();
        stakingProviders = new address[](1);
        stakingProviders[0] = address(mockStakingProvider);

        ammProviders = new address[](1);
        mockAMMProvider = new MockAMMProvider();
        ammProviders[0] = address(mockAMMProvider);

        subscriptionAddress = makeAddr("subscriptionAddress");
        ownerAddress = tx.origin;
        assetManagerAddress = makeAddr("assetManager");
        WhiteList whiteList = new WhiteList();
        whiteListAddress = address(whiteList);
        vm.startPrank(tx.origin);
        whiteList.grantRole(whiteList.ASSET_MANAGER_ROLE(), tx.origin);
        whiteList.grantRole(whiteList.STABLE_COIN_MANAGER_ROLE(), tx.origin);
        whiteList.grantRole(whiteList.LENDING_MANAGER_ROLE(), tx.origin);
        whiteList.grantRole(whiteList.STAKING_MANAGER_ROLE(), tx.origin);
        whiteList.grantRole(whiteList.AMM_MANAGER_ROLE(), tx.origin);
        whiteList.addAssets(assets);
        whiteList.addStableCoins(stableCoins);
        whiteList.addLendingProviders(lendingProviders);
        whiteList.addStakingProviders(stakingProviders);
        whiteList.addAMMProviders(ammProviders);
        vm.stopPrank();
    }

    function getClonedProvider(address provider) external view returns (address) {
        return _assetManager.clonedProviders[provider];
    }

    function cloneProviderForTesting(address provider) external returns (address) {
        return AssetManagerLogic.cloneProvider(_assetManager, provider);
    }

    function prepareStakingProvider() external {
        address cloned = this.cloneProviderForTesting(address(mockStakingProvider));
        MockStakingProvider(cloned).setWethAddress(mockWETH);
    }

    function doInitialize() public {
        this.initialize(
            whiteListAddress,
            subscriptionAddress,
            mockWETH,
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
        this.setRebalanceConfig(address(mockWETH), rebalanceConfig);
    }

    function test_RevertOnlyAssetManager() public {
        this.doInitialize();
        vm.expectRevert(OnlyAssetManager.selector);
        this.supply(address(mockLendingProvider), address(mockWETH), 1 ether);
        vm.expectRevert(OnlyAssetManager.selector);
        this.withdraw(address(mockLendingProvider), address(mockWETH), 1 ether);
        vm.expectRevert(OnlyAssetManager.selector);
        this.rebalance(address(mockAMMProvider), address(mockWBTC), address(mockUSDT), 1 ether, 1 ether, "");
    }

    function test_SupplyRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(mockLendingProvider), address(0), 1 ether);
    }

    function test_SupplyRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(mockLendingProvider), address(mockWETH), 0);
    }

    function test_WithdrawRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(address(mockLendingProvider), address(mockWETH), 0);
    }

    function test_WithdrawRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(address(mockLendingProvider), address(0), 1 ether);
    }

    function test_revertETHToWETH() public {
        this.doInitialize();
        vm.expectRevert(OnlyAssetManager.selector);
        this.ETHToWETH(1 ether);
    }

    function test_ETHToWETHSuccess() public {
        this.doInitialize();
        vm.deal(address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.ETHToWETH(1 ether);
        assertEq(WETH(payable(mockWETH)).balanceOf(address(this)), 1 ether);
    }

    /// @dev Regression: plain ETH sends must not revert (Vault.receive). Matches wallet "Send ETH" (empty calldata).
    function test_ethDeposit_viaReceive_thenETHToWETH() public {
        this.doInitialize();

        uint256 amount = 0.1 ether;
        address depositor = makeAddr("ethDepositor");
        uint256 ethBefore = address(this).balance;
        uint256 wethBefore = WETH(payable(mockWETH)).balanceOf(address(this));

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success, bytes memory returnData) = address(this).call{value: amount}("");

        assertTrue(success, string(returnData));
        assertEq(address(this).balance - ethBefore, amount);
        assertEq(WETH(payable(mockWETH)).balanceOf(address(this)), wethBefore);

        uint256 ethAfterDeposit = address(this).balance;
        vm.prank(assetManagerAddress);
        this.ETHToWETH(amount);

        assertEq(address(this).balance, ethAfterDeposit - amount);
        assertEq(WETH(payable(mockWETH)).balanceOf(address(this)), wethBefore + amount);
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
        address invalidLendingProvider = address(new MockLendingProvider());
        vm.expectRevert(InvalidLendingProvider.selector);
        vm.prank(assetManagerAddress);
        this.supply(invalidLendingProvider, address(mockWETH), 1 ether);
    }

    function test_SupplySuccess() public {
        this.doInitialize();

        MockERC20 mockToken = new MockERC20("MockToken", "MTK", 18);

        uint256 supplyAmount = 1000 * 1e18;

        deal(address(mockToken), address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        this.supply(address(mockLendingProvider), address(mockToken), supplyAmount);

        address clonedProvider = this.getClonedProvider(address(mockLendingProvider));
        require(clonedProvider != address(0), "Provider should be cloned");

        uint256 balanceAfter = MockLendingProvider(clonedProvider).getSuppliedBalance(address(mockToken));
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
        this.supply(address(mockLendingProvider), address(mockToken), supplyAmount);

        address clonedProvider = this.getClonedProvider(address(mockLendingProvider));

        uint256 balanceBefore = mockToken.balanceOf(address(this));

        vm.prank(assetManagerAddress);
        this.withdraw(address(mockLendingProvider), address(mockToken), withdrawAmount);

        uint256 balanceAfter = mockToken.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, withdrawAmount);

        assertEq(
            MockLendingProvider(clonedProvider).getSuppliedBalance(address(mockToken)), supplyAmount - withdrawAmount
        );
    }

    function test_LendingProviderRevertIfNotWhiteListed() public {
        this.doInitialize();

        address invalidLendingProvider = makeAddr("InvalidLendingProvider");
        vm.expectRevert(InvalidLendingProvider.selector);
        vm.prank(assetManagerAddress);
        this.supply(invalidLendingProvider, address(mockWETH), 1 ether);
    }

    function test_SupplyFromDeprecatedLendingProvider() public {
        this.doInitialize();
        vm.prank(tx.origin);
        WhiteList(whiteListAddress).deprecateLendingProviders(lendingProviders);
        vm.expectRevert(Deprecated.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(mockLendingProvider), address(mockWETH), 1 ether);
    }

    function test_WithdrawMoneySuccessFromDeprecateLendingProvider() public {
        this.doInitialize();
        deal(address(mockWETH), address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.supply(address(mockLendingProvider), address(mockWETH), 1 ether);
        vm.prank(tx.origin);
        WhiteList(whiteListAddress).deprecateLendingProviders(lendingProviders);
        vm.prank(assetManagerAddress);
        this.withdraw(address(mockLendingProvider), address(mockWETH), 1 ether);
    }

    function test_WithdrawFromInvalidLendingProvider() public {
        this.doInitialize();
        address invalidLendingProvider = makeAddr("InvalidLendingProvider");
        vm.expectRevert(InvalidLendingProvider.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(invalidLendingProvider, address(mockWETH), 1 ether);
    }

    function test_GetBalance() public {
        this.doInitialize();
        uint256 depositAmount = 5 ether;

        uint256 balance = this.getSuppliedBalance(address(mockLendingProvider), address(mockWETH));
        assertEq(balance, 0);

        deal(address(mockWETH), address(this), depositAmount);
        MockERC20(mockWETH).approve(address(this), depositAmount);

        vm.prank(assetManagerAddress);
        this.supply(address(mockLendingProvider), address(mockWETH), depositAmount);

        balance = this.getSuppliedBalance(address(mockLendingProvider), address(mockWETH));
        assertEq(balance, depositAmount);
    }

    function test_GetBalance_InvalidLendingProvider() public {
        this.doInitialize();
        address invalidLendingProvider = makeAddr("InvalidLendingProvider");

        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidLendingProvider.selector);
        this.getSuppliedBalance(invalidLendingProvider, address(mockWETH));
    }

    function test_GetBalanceFromDeprecatedLendingProvider() public {
        this.doInitialize();
        vm.prank(tx.origin);
        WhiteList(whiteListAddress).deprecateLendingProviders(lendingProviders);
        uint256 balance = this.getSuppliedBalance(address(mockLendingProvider), address(mockWETH));
        assertEq(balance, 0);
    }

    function test_RebalanceMaxAmount_ExceedsRebalanceConfig() public {
        this.doInitialize();
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: 0, minimalDuration: 7 days, maxAmount: 999});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mockWETH), rebalanceConfig);
        uint256 fromBalance = 1000 * 1e18;
        uint256 sellAmount = 100 * 1e18;

        deal(address(mockWETH), address(this), fromBalance);
        MockERC20(mockWETH).approve(address(this), sellAmount);

        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.expectRevert(RebalanceMaxAmount.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);
    }

    function test_RebalanceMaxAmount_WithinLimit() public {
        this.doInitialize();

        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 1000});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mockWETH), rebalanceConfig);

        uint256 fromBalance = 1000 * 1e18;
        uint256 sellAmount = 100 * 1e18;

        deal(address(mockWETH), address(this), fromBalance);
        MockERC20(mockWETH).approve(address(this), fromBalance);

        address clonedAMMProvider = this.cloneProviderForTesting(address(mockAMMProvider));

        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), clonedAMMProvider, buyAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);

        assertEq(MockERC20(mockWETH).balanceOf(address(this)), fromBalance - sellAmount);
        assertEq(MockERC20(mockUSDT).balanceOf(address(this)), buyAmount);
    }

    function test_RebalanceMaxAmount_ZeroSkipsCheck() public {
        this.doInitialize();

        RebalanceConfig memory rebalanceConfig = RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mockWETH), rebalanceConfig);

        uint256 fromBalance = 1000 * 1e18;
        uint256 sellAmount = 500 * 1e18;

        deal(address(mockWETH), address(this), fromBalance);
        MockERC20(mockWETH).approve(address(this), fromBalance);

        address clonedAMMProvider = this.cloneProviderForTesting(address(mockAMMProvider));

        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), clonedAMMProvider, buyAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFromCheck_RevertsWhenFromNotVaultAsset() public {
        this.doInitialize();

        RebalanceConfig memory rebalanceConfig = RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mockUSDT), rebalanceConfig);

        address invalidFrom = makeAddr("invalidFromAsset");
        uint256 sellAmount = 1 ether;
        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(invalidFrom, sellAmount, address(mockUSDT), buyAmount);

        vm.expectRevert(NotWhiteListed.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), invalidFrom, address(mockUSDT), sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFromCheck_MinimalBalanceNotMet_WhenRemainingBelowMinimal() public {
        this.doInitialize();

        uint256 minimalBalance = 100 ether;
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: minimalBalance, minimalDuration: 1, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mockWETH), rebalanceConfig);

        uint256 fromBalance = 1000 ether;
        uint256 sellAmount = 950 ether;

        deal(address(mockWETH), address(this), fromBalance);
        MockERC20(mockWETH).approve(address(this), fromBalance);

        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFromCheck_MinimalBalanceNotMet_WhenSellExceedsBalance() public {
        this.doInitialize();

        uint256 minimalBalance = 100 ether;
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: minimalBalance, minimalDuration: 1, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mockWETH), rebalanceConfig);

        uint256 fromBalance = 50 ether;
        uint256 sellAmount = 100 ether;

        deal(address(mockWETH), address(this), fromBalance);
        MockERC20(mockWETH).approve(address(this), fromBalance);

        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFromCheck_MinimalBalance_SucceedsWhenRemainingAtLeastMinimal() public {
        this.doInitialize();

        uint256 minimalBalance = 100 ether;
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: minimalBalance, minimalDuration: 1, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mockWETH), rebalanceConfig);

        uint256 fromBalance = 1000 ether;
        uint256 sellAmount = 900 ether;

        deal(address(mockWETH), address(this), fromBalance);
        MockERC20(mockWETH).approve(address(this), fromBalance);

        address clonedAMMProvider = this.cloneProviderForTesting(address(mockAMMProvider));

        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), clonedAMMProvider, buyAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);

        assertEq(MockERC20(mockWETH).balanceOf(address(this)), minimalBalance);
        assertEq(MockERC20(mockUSDT).balanceOf(address(this)), buyAmount);
    }

    function test_RebalanceFromCheck_RebalanceInMinimalTime_RevertsWhenFromDurationNotElapsed() public {
        this.doInitialize();

        uint256 minimalDuration = 7 days;
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: 0, minimalDuration: minimalDuration, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mockWETH), rebalanceConfig);

        uint256 fromBalance = 10 ether;
        uint256 sellAmount = 1 ether;
        uint256 buyAmount = 10 * 1e6;

        deal(address(mockWETH), address(this), fromBalance);
        MockERC20(mockWETH).approve(address(this), fromBalance);

        address clonedAMMProvider = this.cloneProviderForTesting(address(mockAMMProvider));
        deal(address(mockUSDT), clonedAMMProvider, buyAmount * 2);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);

        vm.expectRevert(RebalanceInMinimalTime.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFromCheck_RebalanceInMinimalTime_SucceedsAfterFromDurationElapsed() public {
        this.doInitialize();

        uint256 minimalDuration = 7 days;
        RebalanceConfig memory rebalanceConfig =
            RebalanceConfig({minimalBalance: 0, minimalDuration: minimalDuration, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mockWETH), rebalanceConfig);

        uint256 fromBalance = 10 ether;
        uint256 sellAmount = 1 ether;
        uint256 buyAmount = 10 * 1e6;

        deal(address(mockWETH), address(this), fromBalance);
        MockERC20(mockWETH).approve(address(this), fromBalance);

        address clonedAMMProvider = this.cloneProviderForTesting(address(mockAMMProvider));
        deal(address(mockUSDT), clonedAMMProvider, buyAmount * 2);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);

        vm.warp(block.timestamp + minimalDuration + 1);

        deal(address(mockWETH), address(this), fromBalance);
        MockERC20(mockWETH).approve(address(this), fromBalance);
        deal(address(mockUSDT), clonedAMMProvider, buyAmount);

        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);

        assertEq(MockERC20(mockWETH).balanceOf(address(this)), fromBalance - sellAmount);
        assertEq(MockERC20(mockUSDT).balanceOf(address(this)), buyAmount * 2);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_RevertsWhenBeforeTimestamp() public {
        this.doInitialize();
        RebalanceConfig memory rebalanceConfig = RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mockWETH), rebalanceConfig);

        uint256 disabledUntil = block.timestamp + 100;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(disabledUntil);

        uint256 sellAmount = 1 * 1e18;
        uint256 buyAmount = 10 * 1e6;
        deal(address(mockWETH), address(this), sellAmount);
        address clonedAMMProvider = this.cloneProviderForTesting(address(mockAMMProvider));
        deal(address(mockUSDT), clonedAMMProvider, buyAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.expectRevert(RebalanceDisabled.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_SucceedsAfterTimestamp() public {
        this.doInitialize();
        RebalanceConfig memory rebalanceConfig = RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mockWETH), rebalanceConfig);

        uint256 disabledUntil = block.timestamp + 100;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(disabledUntil);

        vm.warp(disabledUntil + 1);

        uint256 sellAmount = 1 * 1e18;
        uint256 buyAmount = 10 * 1e6;
        deal(address(mockWETH), address(this), sellAmount);
        address clonedAMMProvider = this.cloneProviderForTesting(address(mockAMMProvider));
        deal(address(mockUSDT), clonedAMMProvider, buyAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);

        assertEq(MockERC20(mockWETH).balanceOf(address(this)), 0);
        assertEq(MockERC20(mockUSDT).balanceOf(address(this)), buyAmount);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_SucceedsWhenNeverDisabled() public {
        this.doInitialize();
        RebalanceConfig memory rebalanceConfig = RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 0});
        vm.prank(ownerAddress);
        this.setRebalanceConfig(address(mockWETH), rebalanceConfig);

        uint256 sellAmount = 1 * 1e18;
        uint256 buyAmount = 10 * 1e6;
        deal(address(mockWETH), address(this), sellAmount);
        address clonedAMMProvider = this.cloneProviderForTesting(address(mockAMMProvider));
        deal(address(mockUSDT), clonedAMMProvider, buyAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.prank(assetManagerAddress);
        this.rebalance(address(mockAMMProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);

        assertEq(MockERC20(mockWETH).balanceOf(address(this)), 0);
        assertEq(MockERC20(mockUSDT).balanceOf(address(this)), buyAmount);
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

    function test_DisableAddingAssets_RevertsWhenNotOwner() public {
        this.doInitialize();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Ownable: caller is not the owner");
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
        this.prepareStakingProvider();
        deal(mockWETH, address(this), 1 ether);
        vm.expectRevert(OnlyAssetManager.selector);
        this.stake(address(mockStakingProvider), mockWETH, 1 ether);
    }

    function test_StakeRevertInvalidStakingProvider() public {
        this.doInitialize();
        address invalidStakingProvider = makeAddr("InvalidStakingProvider");
        vm.expectRevert(InvalidStakingProvider.selector);
        vm.prank(assetManagerAddress);
        this.stake(invalidStakingProvider, mockWETH, 1 ether);
    }

    function test_StakeRevertAmountIsZero() public {
        this.doInitialize();
        this.prepareStakingProvider();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.stake(address(mockStakingProvider), mockWETH, 0);
    }

    function test_StakeSuccess() public {
        this.doInitialize();
        this.prepareStakingProvider();
        uint256 stakeAmount = 1 ether;
        deal(mockWETH, address(this), stakeAmount);

        assertEq(this.getStakedBalance(address(mockStakingProvider), mockWETH), 0);

        vm.prank(assetManagerAddress);
        this.stake(address(mockStakingProvider), mockWETH, stakeAmount);

        address clonedProvider = this.getClonedProvider(address(mockStakingProvider));
        assertTrue(clonedProvider != address(0));
        assertEq(MockStakingProvider(clonedProvider).getStakedBalance(mockWETH), stakeAmount);
        assertEq(this.getStakedBalance(address(mockStakingProvider), mockWETH), stakeAmount);
        assertEq(WETH(payable(mockWETH)).balanceOf(address(this)), 0);
    }

    function test_GetStakingBalance() public {
        this.doInitialize();
        this.prepareStakingProvider();
        assertEq(this.getStakedBalance(address(mockStakingProvider), mockWETH), 0);

        uint256 stakeAmount = 2 ether;
        deal(mockWETH, address(this), stakeAmount);
        vm.prank(assetManagerAddress);
        this.stake(address(mockStakingProvider), mockWETH, stakeAmount);

        assertEq(this.getStakedBalance(address(mockStakingProvider), mockWETH), stakeAmount);
    }

    function test_GetStakingBalance_InvalidStakingProvider() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProvider.selector);
        this.getStakedBalance(makeAddr("InvalidStakingProvider"), mockWETH);
    }

    function test_UnstakeSuccess() public {
        this.doInitialize();
        this.prepareStakingProvider();
        uint256 stakeAmount = 1 ether;
        uint256 unstakeAmount = 0.5 ether;
        deal(mockWETH, address(this), stakeAmount);

        vm.prank(assetManagerAddress);
        this.stake(address(mockStakingProvider), mockWETH, stakeAmount);
        assertEq(this.getStakedBalance(address(mockStakingProvider), mockWETH), stakeAmount);

        vm.prank(assetManagerAddress);
        this.unstake(address(mockStakingProvider), mockWETH, unstakeAmount);
        assertEq(this.getStakedBalance(address(mockStakingProvider), mockWETH), stakeAmount - unstakeAmount);

        uint256[] memory requestIds = this.getUnstakeRequestIds(address(mockStakingProvider));
        assertEq(requestIds.length, 1);

        uint256 vaultBalanceBefore = WETH(payable(mockWETH)).balanceOf(address(this));
        vm.prank(assetManagerAddress);
        this.claimUnstaked(address(mockStakingProvider), requestIds);
        uint256 vaultBalanceAfter = WETH(payable(mockWETH)).balanceOf(address(this));
        assertEq(vaultBalanceAfter - vaultBalanceBefore, unstakeAmount);
    }

    function test_ClaimSuccess() public {
        this.doInitialize();
        this.prepareStakingProvider();
        uint256 stakeAmount = 1 ether;
        uint256 unstakeAmount = 0.5 ether;
        deal(mockWETH, address(this), stakeAmount);

        vm.prank(assetManagerAddress);
        this.stake(address(mockStakingProvider), mockWETH, stakeAmount);
        vm.prank(assetManagerAddress);
        this.unstake(address(mockStakingProvider), mockWETH, unstakeAmount);

        uint256[] memory requestIds = this.getUnstakeRequestIds(address(mockStakingProvider));
        assertEq(requestIds.length, 1);

        uint256 vaultBalanceBefore = WETH(payable(mockWETH)).balanceOf(address(this));
        vm.prank(assetManagerAddress);
        this.claimUnstaked(address(mockStakingProvider), requestIds);
        uint256 vaultBalanceAfter = WETH(payable(mockWETH)).balanceOf(address(this));
        assertEq(vaultBalanceAfter - vaultBalanceBefore, unstakeAmount);

        uint256[] memory remaining = this.getUnstakeRequestIds(address(mockStakingProvider));
        assertEq(remaining.length, 0);
    }

    function test_ClaimRevertOnlyAssetManager() public {
        this.doInitialize();
        this.prepareStakingProvider();
        uint256[] memory requestIds = new uint256[](0);
        vm.expectRevert(OnlyAssetManager.selector);
        this.claimUnstaked(address(mockStakingProvider), requestIds);
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
        this.prepareStakingProvider();
        uint256[] memory requestIds = new uint256[](0);
        vm.prank(assetManagerAddress);
        this.claimUnstaked(address(mockStakingProvider), requestIds);
    }

    function test_UnstakeRevertAmountIsZero() public {
        this.doInitialize();
        this.prepareStakingProvider();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.unstake(address(mockStakingProvider), mockWETH, 0);
    }

    function test_UnstakeRevertInvalidStakingProvider() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProvider.selector);
        vm.prank(assetManagerAddress);
        this.unstake(makeAddr("InvalidStakingProvider"), mockWETH, 1 ether);
    }

    function test_GetUnstakeRequestIds() public {
        this.doInitialize();
        this.prepareStakingProvider();
        uint256[] memory ids = this.getUnstakeRequestIds(address(mockStakingProvider));
        assertEq(ids.length, 0);

        deal(mockWETH, address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.stake(address(mockStakingProvider), mockWETH, 1 ether);
        vm.prank(assetManagerAddress);
        this.unstake(address(mockStakingProvider), mockWETH, 0.5 ether);

        ids = this.getUnstakeRequestIds(address(mockStakingProvider));
        assertEq(ids.length, 1);
    }

    function test_GetUnstakeRequestIds_InvalidStakingProvider() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProvider.selector);
        this.getUnstakeRequestIds(makeAddr("InvalidStakingProvider"));
    }

    function test_SupplyAllowanceIsZeroAfterSuccess() public {
        this.doInitialize();

        MockERC20 mockToken = new MockERC20("MockToken", "MTK", 18);
        uint256 supplyAmount = 1000 * 1e18;
        deal(address(mockToken), address(this), supplyAmount);

        vm.prank(assetManagerAddress);
        this.supply(address(mockLendingProvider), address(mockToken), supplyAmount);

        address clonedProvider = this.getClonedProvider(address(mockLendingProvider));
        assertEq(mockToken.allowance(address(this), clonedProvider), 0, "Allowance should be 0 after supply");
    }

    function test_SupplySucceedsWithPreExistingResidualAllowance() public {
        this.doInitialize();

        MockERC20 mockToken = new MockERC20("MockToken", "MTK", 18);
        uint256 supplyAmount = 1000 * 1e18;
        deal(address(mockToken), address(this), supplyAmount);

        address clonedProvider = this.cloneProviderForTesting(address(mockLendingProvider));

        mockToken.approve(clonedProvider, 1);
        assertEq(mockToken.allowance(address(this), clonedProvider), 1, "Pre-condition: residual allowance must exist");

        vm.prank(assetManagerAddress);
        this.supply(address(mockLendingProvider), address(mockToken), supplyAmount);

        assertEq(mockToken.allowance(address(this), clonedProvider), 0, "Allowance should be 0 after successful supply");
        assertEq(MockLendingProvider(clonedProvider).getSuppliedBalance(address(mockToken)), supplyAmount);
    }

    function test_StakeSucceedsWithPreExistingResidualAllowance() public {
        this.doInitialize();
        this.prepareStakingProvider();

        uint256 stakeAmount = 1 ether;
        deal(mockWETH, address(this), stakeAmount);

        address clonedProvider = this.getClonedProvider(address(mockStakingProvider));
        assertTrue(clonedProvider != address(0), "Clone must exist after prepareStakingProvider");

        WETH(payable(mockWETH)).approve(clonedProvider, 1);
        assertEq(
            WETH(payable(mockWETH)).allowance(address(this), clonedProvider),
            1,
            "Pre-condition: residual allowance must exist"
        );

        vm.prank(assetManagerAddress);
        this.stake(address(mockStakingProvider), mockWETH, stakeAmount);

        assertEq(
            WETH(payable(mockWETH)).allowance(address(this), clonedProvider),
            0,
            "Allowance should be 0 after successful stake"
        );
        assertEq(MockStakingProvider(clonedProvider).getStakedBalance(mockWETH), stakeAmount);
    }
}
