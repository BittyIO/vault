// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {AmountIsZero, AddressZero} from "../../src/interfaces/IVault.sol";
import {
    InvalidLendingProvider,
    InvalidStakingProvider,
    RebalanceMaxPercentage,
    RebalanceDisabled,
    DisableRebalanceUntilTimestampTooEarly,
    OnlyAssetManager
} from "../../src/interfaces/IAssetManager.sol";
import {Deprecated} from "../../src/interfaces/IWhiteList.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {MockLendingProvider} from "../mock/MockLendingProvider.sol";
import {MockStakingProvider} from "../mock/MockStakingProvider.sol";
import {MockAMMProvider} from "../mock/MockAMMProvider.sol";
import {WhiteList} from "../../src/WhiteList.sol";
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
    MockAMMProvider public mockSwapProvider;
    address public whiteListAddress;
    address[] public assets;
    address[] public stableCoins;
    address[] public lendingProviders;
    address[] public stakingProviders;
    address[] public swapProviders;
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

        swapProviders = new address[](1);
        mockSwapProvider = new MockAMMProvider();
        swapProviders[0] = address(mockSwapProvider);
        ownerAddress = tx.origin;
        assetManagerAddress = makeAddr("assetManager");
        WhiteList whiteList = new WhiteList();
        whiteListAddress = address(whiteList);
        vm.startPrank(tx.origin);
        whiteList.addAssets(assets);
        whiteList.addStableCoins(stableCoins);
        whiteList.addLendingProviders(lendingProviders);
        whiteList.addStakingProviders(stakingProviders);
        whiteList.addSwapProviders(swapProviders);
        vm.stopPrank();
    }

    function getClonedProvider(address provider) external view returns (address) {
        return _assetManager.clonedProviders[provider];
    }

    function cloneProviderForTesting(address provider) external returns (address) {
        return AssetManagerLogic.cloneProvider(_assetManager, provider);
    }

    /// @dev Call after doInitialize() to prepare MockStakingProvider clone with WETH (clone has no weth set by default).
    function prepareStakingProvider() external {
        address cloned = this.cloneProviderForTesting(address(mockStakingProvider));
        MockStakingProvider(cloned).setWethAddress(mockWETH);
    }

    function test_InitializeWithAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        this.initialize(address(0), mockWETH, assets, stableCoins, lendingProviders, stakingProviders, swapProviders);
        vm.expectRevert(AddressZero.selector);
        this.initialize(
            whiteListAddress, address(0), assets, stableCoins, lendingProviders, stakingProviders, swapProviders
        );
    }

    function doInitialize() public {
        this.initialize(
            whiteListAddress, mockWETH, assets, stableCoins, lendingProviders, stakingProviders, swapProviders
        );
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress);
    }

    function test_SetAssetConfig() public {
        this.doInitialize();
        AssetConfig memory assetConfig =
            AssetConfig({minimalBalance: 100 * 1e6, minimalDurationBetweenRebalances: 30, maxRebalancePercentage: 0});
        vm.prank(ownerAddress);
        this.setAssetConfig(address(mockWETH), assetConfig);
    }

    function test_RevertOnlyAssetManager() public {
        this.doInitialize();
        vm.expectRevert(OnlyAssetManager.selector);
        this.supply(address(mockLendingProvider), address(mockWETH), 1 ether);
        vm.expectRevert(OnlyAssetManager.selector);
        this.withdraw(address(mockLendingProvider), address(mockWETH), 1 ether);
        vm.expectRevert(OnlyAssetManager.selector);
        this.rebalance(address(mockSwapProvider), address(mockWBTC), address(mockUSDT), 1 ether, 1 ether, "");
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

        uint256 balanceAfter = MockLendingProvider(clonedProvider).getLendingBalance(address(mockToken));
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
            MockLendingProvider(clonedProvider).getLendingBalance(address(mockToken)), supplyAmount - withdrawAmount
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

    function test_GetAllAssetConfigKeys() public {
        this.doInitialize();
        AssetConfig memory assetConfig1 =
            AssetConfig({minimalBalance: 100 * 1e6, minimalDurationBetweenRebalances: 30, maxRebalancePercentage: 0});
        AssetConfig memory assetConfig2 =
            AssetConfig({minimalBalance: 200 * 1e6, minimalDurationBetweenRebalances: 60, maxRebalancePercentage: 0});

        vm.prank(ownerAddress);
        this.setAssetConfig(address(mockWETH), assetConfig1);
        vm.prank(ownerAddress);
        this.setAssetConfig(address(mockWBTC), assetConfig2);

        address[] memory keys = this.getAllAssetConfigKeys();
        assertEq(keys.length, 2);
        assertTrue(keys[0] == address(mockWETH) || keys[1] == address(mockWETH));
        assertTrue(keys[0] == address(mockWBTC) || keys[1] == address(mockWBTC));
    }

    function test_GetAllLastRebalanceTimestampKeys() public {
        this.doInitialize();
        AssetConfig memory assetConfig =
            AssetConfig({minimalBalance: 0, minimalDurationBetweenRebalances: 30, maxRebalancePercentage: 0});
        vm.prank(ownerAddress);
        this.setAssetConfig(address(mockWETH), assetConfig);

        uint256 sellAmount = 1 * 1e6;
        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        address clonedSwapProvider = this.cloneProviderForTesting(address(mockSwapProvider));
        deal(address(mockWETH), address(this), sellAmount);
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);

        vm.warp(block.timestamp + 31);
        vm.prank(assetManagerAddress);
        this.rebalance(address(mockSwapProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);

        address[] memory keys = this.getAllLastRebalanceTimestampKeys();
        assertEq(keys.length, 1);
        assertEq(keys[0], address(mockWETH));
    }

    function test_GetBalance() public {
        this.doInitialize();
        uint256 depositAmount = 5 ether;

        uint256 balance = this.getLendingBalance(address(mockLendingProvider), address(mockWETH));
        assertEq(balance, 0);

        deal(address(mockWETH), address(this), depositAmount);
        MockERC20(mockWETH).approve(address(this), depositAmount);

        vm.prank(assetManagerAddress);
        this.supply(address(mockLendingProvider), address(mockWETH), depositAmount);

        balance = this.getLendingBalance(address(mockLendingProvider), address(mockWETH));
        assertEq(balance, depositAmount);
    }

    function test_GetBalance_InvalidLendingProvider() public {
        this.doInitialize();
        address invalidLendingProvider = makeAddr("InvalidLendingProvider");

        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidLendingProvider.selector);
        this.getLendingBalance(invalidLendingProvider, address(mockWETH));
    }

    function test_GetBalanceFromDeprecatedLendingProvider() public {
        this.doInitialize();
        vm.prank(tx.origin);
        WhiteList(whiteListAddress).deprecateLendingProviders(lendingProviders);
        uint256 balance = this.getLendingBalance(address(mockLendingProvider), address(mockWETH));
        assertEq(balance, 0);
    }

    // ---------- rebalance tests ----------

    function test_RebalanceMaxPercentage_ExceedsAssetConfig() public {
        this.doInitialize();
        AssetConfig memory assetConfig =
            AssetConfig({minimalBalance: 0, minimalDurationBetweenRebalances: 0, maxRebalancePercentage: 999});
        vm.prank(ownerAddress);
        this.setAssetConfig(address(mockWETH), assetConfig);
        uint256 fromBalance = 1000 * 1e18;
        uint256 sellAmount = 100 * 1e18;

        deal(address(mockWETH), address(this), fromBalance);
        MockERC20(mockWETH).approve(address(this), sellAmount);

        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.expectRevert(RebalanceMaxPercentage.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(address(mockSwapProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);
    }

    function test_RebalanceMaxPercentage_WithinLimit() public {
        this.doInitialize();

        AssetConfig memory assetConfig =
            AssetConfig({minimalBalance: 0, minimalDurationBetweenRebalances: 0, maxRebalancePercentage: 1000});
        vm.prank(ownerAddress);
        this.setAssetConfig(address(mockWETH), assetConfig);

        uint256 fromBalance = 1000 * 1e18;
        uint256 sellAmount = 100 * 1e18;

        deal(address(mockWETH), address(this), fromBalance);
        MockERC20(mockWETH).approve(address(this), fromBalance);

        address clonedSwapProvider = this.cloneProviderForTesting(address(mockSwapProvider));

        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.prank(assetManagerAddress);
        this.rebalance(address(mockSwapProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);

        assertEq(MockERC20(mockWETH).balanceOf(address(this)), fromBalance - sellAmount);
        assertEq(MockERC20(mockUSDT).balanceOf(address(this)), buyAmount);
    }

    function test_RebalanceMaxPercentage_ZeroSkipsCheck() public {
        this.doInitialize();

        AssetConfig memory assetConfig =
            AssetConfig({minimalBalance: 0, minimalDurationBetweenRebalances: 0, maxRebalancePercentage: 0});
        vm.prank(ownerAddress);
        this.setAssetConfig(address(mockWETH), assetConfig);

        uint256 fromBalance = 1000 * 1e18;
        uint256 sellAmount = 500 * 1e18;

        deal(address(mockWETH), address(this), fromBalance);
        MockERC20(mockWETH).approve(address(this), fromBalance);

        address clonedSwapProvider = this.cloneProviderForTesting(address(mockSwapProvider));

        uint256 buyAmount = 10 * 1e6;
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.prank(assetManagerAddress);
        this.rebalance(address(mockSwapProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_RevertsWhenBeforeTimestamp() public {
        this.doInitialize();
        AssetConfig memory assetConfig =
            AssetConfig({minimalBalance: 0, minimalDurationBetweenRebalances: 0, maxRebalancePercentage: 0});
        vm.prank(ownerAddress);
        this.setAssetConfig(address(mockWETH), assetConfig);

        uint256 disabledUntil = block.timestamp + 100;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(disabledUntil);

        uint256 sellAmount = 1 * 1e18;
        uint256 buyAmount = 10 * 1e6;
        deal(address(mockWETH), address(this), sellAmount);
        address clonedSwapProvider = this.cloneProviderForTesting(address(mockSwapProvider));
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.expectRevert(RebalanceDisabled.selector);
        vm.prank(assetManagerAddress);
        this.rebalance(address(mockSwapProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_SucceedsAfterTimestamp() public {
        this.doInitialize();
        AssetConfig memory assetConfig =
            AssetConfig({minimalBalance: 0, minimalDurationBetweenRebalances: 0, maxRebalancePercentage: 0});
        vm.prank(ownerAddress);
        this.setAssetConfig(address(mockWETH), assetConfig);

        uint256 disabledUntil = block.timestamp + 100;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(disabledUntil);

        vm.warp(disabledUntil + 1);

        uint256 sellAmount = 1 * 1e18;
        uint256 buyAmount = 10 * 1e6;
        deal(address(mockWETH), address(this), sellAmount);
        address clonedSwapProvider = this.cloneProviderForTesting(address(mockSwapProvider));
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.prank(assetManagerAddress);
        this.rebalance(address(mockSwapProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);

        assertEq(MockERC20(mockWETH).balanceOf(address(this)), 0);
        assertEq(MockERC20(mockUSDT).balanceOf(address(this)), buyAmount);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_SucceedsWhenNeverDisabled() public {
        this.doInitialize();
        AssetConfig memory assetConfig =
            AssetConfig({minimalBalance: 0, minimalDurationBetweenRebalances: 0, maxRebalancePercentage: 0});
        vm.prank(ownerAddress);
        this.setAssetConfig(address(mockWETH), assetConfig);

        uint256 sellAmount = 1 * 1e18;
        uint256 buyAmount = 10 * 1e6;
        deal(address(mockWETH), address(this), sellAmount);
        address clonedSwapProvider = this.cloneProviderForTesting(address(mockSwapProvider));
        deal(address(mockUSDT), clonedSwapProvider, buyAmount);
        bytes memory swapData = abi.encode(address(mockWETH), sellAmount, address(mockUSDT), buyAmount);

        vm.prank(assetManagerAddress);
        this.rebalance(address(mockSwapProvider), address(mockWETH), address(mockUSDT), sellAmount, buyAmount, swapData);

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

    // ---------- disableAddingAssets tests ----------

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

    // ---------- staking tests ----------

    function test_StakeRevertOnlyAssetManager() public {
        this.doInitialize();
        this.prepareStakingProvider();
        deal(mockWETH, address(this), 1 ether);
        vm.expectRevert(OnlyAssetManager.selector);
        this.stake(address(mockStakingProvider), 1 ether);
    }

    function test_StakeRevertInvalidStakingProvider() public {
        this.doInitialize();
        address invalidStakingProvider = makeAddr("InvalidStakingProvider");
        vm.expectRevert(InvalidStakingProvider.selector);
        vm.prank(assetManagerAddress);
        this.stake(invalidStakingProvider, 1 ether);
    }

    function test_StakeRevertAmountIsZero() public {
        this.doInitialize();
        this.prepareStakingProvider();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.stake(address(mockStakingProvider), 0);
    }

    function test_StakeSuccess() public {
        this.doInitialize();
        this.prepareStakingProvider();
        uint256 stakeAmount = 1 ether;
        deal(mockWETH, address(this), stakeAmount);

        assertEq(this.getStakingBalance(address(mockStakingProvider)), 0);

        vm.prank(assetManagerAddress);
        this.stake(address(mockStakingProvider), stakeAmount);

        address clonedProvider = this.getClonedProvider(address(mockStakingProvider));
        assertTrue(clonedProvider != address(0));
        assertEq(MockStakingProvider(clonedProvider).getStakingBalance(), stakeAmount);
        assertEq(this.getStakingBalance(address(mockStakingProvider)), stakeAmount);
        assertEq(WETH(payable(mockWETH)).balanceOf(address(this)), 0);
    }

    function test_GetStakingBalance() public {
        this.doInitialize();
        this.prepareStakingProvider();
        assertEq(this.getStakingBalance(address(mockStakingProvider)), 0);

        uint256 stakeAmount = 2 ether;
        deal(mockWETH, address(this), stakeAmount);
        vm.prank(assetManagerAddress);
        this.stake(address(mockStakingProvider), stakeAmount);

        assertEq(this.getStakingBalance(address(mockStakingProvider)), stakeAmount);
    }

    function test_GetStakingBalance_InvalidStakingProvider() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProvider.selector);
        this.getStakingBalance(makeAddr("InvalidStakingProvider"));
    }

    function test_UnstakeSuccess() public {
        this.doInitialize();
        this.prepareStakingProvider();
        uint256 stakeAmount = 1 ether;
        uint256 unstakeAmount = 0.5 ether;
        deal(mockWETH, address(this), stakeAmount);

        vm.prank(assetManagerAddress);
        this.stake(address(mockStakingProvider), stakeAmount);
        assertEq(this.getStakingBalance(address(mockStakingProvider)), stakeAmount);

        vm.prank(assetManagerAddress);
        this.unstake(address(mockStakingProvider), unstakeAmount);
        assertEq(this.getStakingBalance(address(mockStakingProvider)), stakeAmount - unstakeAmount);

        address clonedProvider = this.getClonedProvider(address(mockStakingProvider));
        uint256[] memory requestIds = this.getUnstakeRequestIds(address(mockStakingProvider));
        assertEq(requestIds.length, 1);

        uint256 claimerBalanceBefore = WETH(payable(mockWETH)).balanceOf(assetManagerAddress);
        vm.prank(assetManagerAddress);
        MockStakingProvider(clonedProvider).claim();
        uint256 claimerBalanceAfter = WETH(payable(mockWETH)).balanceOf(assetManagerAddress);
        assertEq(claimerBalanceAfter - claimerBalanceBefore, unstakeAmount);
    }

    function test_UnstakeRevertAmountIsZero() public {
        this.doInitialize();
        this.prepareStakingProvider();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.unstake(address(mockStakingProvider), 0);
    }

    function test_UnstakeRevertInvalidStakingProvider() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProvider.selector);
        vm.prank(assetManagerAddress);
        this.unstake(makeAddr("InvalidStakingProvider"), 1 ether);
    }

    function test_GetUnstakeRequestIds() public {
        this.doInitialize();
        this.prepareStakingProvider();
        uint256[] memory ids = this.getUnstakeRequestIds(address(mockStakingProvider));
        assertEq(ids.length, 0);

        deal(mockWETH, address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.stake(address(mockStakingProvider), 1 ether);
        vm.prank(assetManagerAddress);
        this.unstake(address(mockStakingProvider), 0.5 ether);

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
        assertEq(MockLendingProvider(clonedProvider).getLendingBalance(address(mockToken)), supplyAmount);
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
        this.stake(address(mockStakingProvider), stakeAmount);

        assertEq(
            WETH(payable(mockWETH)).allowance(address(this), clonedProvider),
            0,
            "Allowance should be 0 after successful stake"
        );
        assertEq(MockStakingProvider(clonedProvider).getStakingBalance(), stakeAmount);
    }
}

