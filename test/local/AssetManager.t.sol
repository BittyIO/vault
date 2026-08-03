// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {AmountIsZero, AddressZero, NotInitialized} from "../../src/interfaces/IBittyV1Vault.sol";
import {RiskControlLevel} from "../../src/interfaces/IBittyV1Vault.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {
    InvalidLendingProtocol,
    InvalidStakingProtocol,
    InvalidAMMProtocol,
    RebalanceDisabled,
    MinimalBalanceNotMet,
    TradeSizeExceeded,
    TradeInInterval,
    TradeMustTouchStableCoin,
    TradeLimitExpired,
    TradeInvestedTotalExceeded,
    StableCoinInvestCapZero,
    NotAssetManager,
    DisableRebalanceUntilTimestampTooEarly,
    DisableRebalanceUntilTimestampTooLong
} from "../../src/interfaces/IBittyV1AssetManager.sol";
import {Deprecated, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1LendingProtocol} from "protocol-contracts/src/interfaces/IBittyV1LendingProtocol.sol";
import {IBittyV1StakingProtocol} from "protocol-contracts/src/interfaces/IBittyV1StakingProtocol.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {mainnet} from "protocol-contracts/script/addresses.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {BittyV1VaultHarness} from "../helpers/BittyV1VaultHarness.sol";
import {AddingAssetsDisabled, AddingProtocolsDisabled} from "../../src/interfaces/IBittyV1Vault.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {ProtocolTestSetup} from "../helpers/ProtocolTestSetup.sol";
import {MockAMMProtocol} from "../helpers/MockAMMProtocol.sol";
import {MockIntentProtocol, MockIntentRegistry} from "../helpers/MockIntentProtocol.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";

contract TestAssetManager is ProtocolTestSetup, BittyV1VaultHarness {
    using Clones for address;

    address public guardAddress;
    address[] public assets;
    address[] public vaultAssets;
    address[] public lendingProtocols;
    address[] public stakingProtocols;
    address[] public ammProtocols;
    address[] public intentProtocols;
    address public ownerAddress;
    address public assetManagerAddress;

    MockIntentRegistry internal intentRegistry;
    MockIntentProtocol internal mockIntent;

    function _validTo() private view returns (uint32) {
        return uint32(block.timestamp + 1 days);
    }

    function setUp() public {
        ownerAddress = tx.origin;
        assetManagerAddress = address(this);

        BittyV1Guard guard = new BittyV1Guard();
        guardAddress = address(guard);

        vm.startPrank(tx.origin);
        guard.grantRole(guard.ASSET_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.STABLE_COIN_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.LENDING_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.STAKING_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.AMM_MANAGER_ROLE(), tx.origin);
        guard.addAssets(_two(mainnet.WETH, WBTC));
        guard.addStableCoins(_two(mainnet.USDT, mainnet.USDC));
        vm.stopPrank();

        setupMainnetForkProtocols(guard);

        intentRegistry = new MockIntentRegistry();
        mockIntent = new MockIntentProtocol(address(intentRegistry), false, false);
        vm.prank(tx.origin);
        guard.addIntentProtocols(_single(address(mockIntent)));

        assets = _two(mainnet.WETH, WBTC);
        vaultAssets = new address[](4);
        vaultAssets[0] = mainnet.WETH;
        vaultAssets[1] = WBTC;
        vaultAssets[2] = mainnet.USDT;
        vaultAssets[3] = mainnet.USDC;
        lendingProtocols = _single(address(aaveProtocol));
        stakingProtocols = _single(address(lidoProtocol));
        ammProtocols = _single(address(uniswapV3Protocol));
        intentProtocols = _single(address(mockIntent));
    }

    function _two(address a, address b) private pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _grantAssetManagerRole(address assetManager) internal {
        vm.prank(ownerAddress);
        this.setAssetManager(assetManager, 0, 0, type(uint64).max, 0);
    }

    function getClonedProvider(address protocol) external view returns (address) {
        return _assetManager.clonedProtocols[protocol];
    }

    function getSettingsInvestedBudget(address assetManager) external view returns (uint64) {
        return
            _assetManager.assetManagerSettings.stableCoinInvestCap
                - _assetManager.assetManagerSettings.stableCoinInvested;
    }

    function getSettingsLastTradeTimestamp(address assetManager) external view returns (uint128) {
        return _assetManager.assetManagerSettings.lastTradeTimestamp;
    }

    function getSettingsInvested(address assetManager) external view returns (uint64) {
        return _assetManager.assetManagerSettings.stableCoinInvested;
    }

    function _setTradeLimit(
        address assetManager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt
    ) internal {
        vm.prank(ownerAddress);
        this.setAssetManager(assetManager, interval, maxStableCoinPerTrade, stableCoinInvestCap, expiredAt);
    }

    function _cloneProtocolForTest(address protocol) private returns (address clonedProtocol) {
        clonedProtocol = _assetManager.clonedProtocols[protocol];
        if (clonedProtocol != address(0)) {
            return clonedProtocol;
        }
        clonedProtocol = protocol.clone();
        IBittyV1Protocol(clonedProtocol).initialize(address(this));
        _assetManager.clonedProtocols[protocol] = clonedProtocol;
    }

    function _initializeWithMockAMM(MockAMMProtocol mockAmm) internal {
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).addAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        this.initialize(
            ownerAddress,
            guardAddress,
            mainnet.WETH,
            vaultAssets,
            lendingProtocols,
            stakingProtocols,
            _single(address(mockAmm)),
            intentProtocols,
            address(0),
            RiskControlLevel.Zero
        );
        _grantAssetManagerRole(assetManagerAddress);
        _cloneProtocolForTest(address(mockAmm));
    }

    function _deprecateVaultAMMProtocols() internal {
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).deprecateAMMProtocols(ammProtocols);
    }

    function _roleError(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    function doInitialize() public {
        this.initialize(
            ownerAddress,
            guardAddress,
            mainnet.WETH,
            vaultAssets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            address(0),
            RiskControlLevel.Zero
        );
        _grantAssetManagerRole(assetManagerAddress);
    }

    function test_DisableAddingProtocols_BlocksAllProtocolTypesIncludingIntent() public {
        address intentProto = makeAddr("intentProtocol");
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addIntentProtocols(_single(intentProto));

        this.doInitialize();

        vm.startPrank(ownerAddress);
        this.disableAddingProtocols();
        assertTrue(this.isAddingProtocolsDisabled(), "adding protocols must be locked");

        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.addLendingProtocols(_single(address(aaveProtocol)));

        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.addStakingProtocols(_single(address(lidoProtocol)));

        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.addAMMProtocols(_single(address(uniswapV3Protocol)));

        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.addIntentProtocols(_single(intentProto));

        vm.stopPrank();
    }

    function test_DisableAddingProtocols_BlocksIntentEvenForRegisteredProtocol() public {
        address intentProto = makeAddr("intentProtocolOnly");
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addIntentProtocols(_single(intentProto));

        this.doInitialize();

        vm.prank(ownerAddress);
        this.addIntentProtocols(_single(intentProto));

        vm.prank(ownerAddress);
        this.disableAddingProtocols();

        vm.prank(ownerAddress);
        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.addIntentProtocols(_single(intentProto));
    }

    function test_CleanExpiredLimitOrders_revertNotInitialized() public {
        vm.expectRevert(NotInitialized.selector);
        this.cleanExpiredLimitOrders(makeAddr("intent"), new bytes32[](0));
    }

    function test_SetMinimalBalance() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, 100 * 1e6);
    }

    function test_RevertOnlyAssetManager() public {
        this.doInitialize();
        address stranger = makeAddr("subscribedStranger");

        vm.prank(stranger);
        vm.expectRevert(NotAssetManager.selector);
        this.supply(address(aaveProtocol), address(mainnet.WETH), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(NotAssetManager.selector);
        this.withdraw(address(aaveProtocol), address(mainnet.WETH), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(NotAssetManager.selector);
        this.limitSell(address(mockIntent), address(WBTC), address(mainnet.USDT), 1 ether, 1 ether, _validTo());
    }

    function test_SupplyRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), address(0), 1 ether);
    }

    function test_SupplyRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), address(mainnet.WETH), 0);
    }

    function test_WithdrawRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), address(mainnet.WETH), 0);
    }

    function test_WithdrawRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), address(0), 1 ether);
    }

    /// @dev A plain ETH send (empty calldata, matching a wallet "Send ETH") is auto-wrapped to WETH
    ///      by BittyV1Vault.receive(), leaving the vault holding WETH and no native ETH.
    function test_ethDeposit_viaReceive_autoWrapsToWETH() public {
        this.doInitialize();

        uint256 amount = 0.1 ether;
        address depositor = makeAddr("ethDepositor");
        uint256 ethBefore = address(this).balance;
        uint256 wethBefore = IERC20(mainnet.WETH).balanceOf(address(this));

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success, bytes memory returnData) = address(this).call{value: amount}("");

        assertTrue(success, string(returnData));
        assertEq(address(this).balance, ethBefore);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)) - wethBefore, amount);
    }

    function test_SupplyRevertInvalidLendingProtocol() public {
        this.doInitialize();
        address invalidLendingProtocol = address(new AaveV3Protocol(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER));
        vm.expectRevert(InvalidLendingProtocol.selector);
        vm.prank(assetManagerAddress);
        this.supply(invalidLendingProtocol, address(mainnet.WETH), 1 ether);
    }

    function test_SupplySuccess() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        require(clonedProtocol != address(0), "Provider should be cloned");

        uint256 balanceAfter = IBittyV1LendingProtocol(clonedProtocol).getSuppliedBalance(mainnet.WETH);
        assertApproxEqAbs(balanceAfter, supplyAmount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_WithdrawSuccess() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        uint256 withdrawAmount = 0.5 ether;

        deal(mainnet.WETH, address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        uint256 balanceBefore = IERC20(mainnet.WETH).balanceOf(address(this));

        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), mainnet.WETH, withdrawAmount);

        uint256 balanceAfter = IERC20(mainnet.WETH).balanceOf(address(this));
        assertApproxEqAbs(balanceAfter - balanceBefore, withdrawAmount, 5);

        uint256 remaining = IBittyV1LendingProtocol(clonedProtocol).getSuppliedBalance(mainnet.WETH);
        assertApproxEqAbs(remaining, supplyAmount - withdrawAmount, 10);
    }

    function test_LendingProviderRevertIfNotRegistered() public {
        this.doInitialize();

        address invalidLendingProtocol = makeAddr("InvalidLendingProtocol");
        vm.expectRevert(InvalidLendingProtocol.selector);
        vm.prank(assetManagerAddress);
        this.supply(invalidLendingProtocol, address(mainnet.WETH), 1 ether);
    }

    function test_SupplyFromDeprecatedLendingProvider() public {
        this.doInitialize();
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).deprecateLendingProtocols(lendingProtocols);
        vm.expectRevert(Deprecated.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), address(mainnet.WETH), 1 ether);
    }

    function test_WithdrawMoneySuccessFromDeprecateLendingProvider() public {
        this.doInitialize();
        deal(address(mainnet.WETH), address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), address(mainnet.WETH), 1 ether);
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).deprecateLendingProtocols(lendingProtocols);
        uint256 supplied = this.getSuppliedBalance(address(aaveProtocol), address(mainnet.WETH));
        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), address(mainnet.WETH), supplied);
    }

    function test_WithdrawWorksAfterLendingProtocolRemoved() public {
        this.doInitialize();
        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, amount);

        vm.prank(ownerAddress);
        this.removeLendingProtocols(_single(address(aaveProtocol)));

        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), mainnet.WETH, amount / 2);

        assertGt(IERC20(mainnet.WETH).balanceOf(address(this)), 0, "withdraw returned funds after removal");
    }

    function test_GetBalance() public {
        this.doInitialize();
        uint256 depositAmount = 5 ether;

        uint256 balance = this.getSuppliedBalance(address(aaveProtocol), address(mainnet.WETH));
        assertEq(balance, 0);

        deal(address(mainnet.WETH), address(this), depositAmount);
        IERC20(mainnet.WETH).approve(address(this), depositAmount);

        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), address(mainnet.WETH), depositAmount);

        balance = this.getSuppliedBalance(address(aaveProtocol), address(mainnet.WETH));
        assertApproxEqAbs(balance, depositAmount, 10);
    }

    function test_GetBalance_UnusedLendingProtocol_ReturnsZero() public {
        this.doInitialize();
        assertEq(this.getSuppliedBalance(makeAddr("UnusedLendingProtocol"), address(mainnet.WETH)), 0);
    }

    function test_GetBalanceFromDeprecatedLendingProvider() public {
        this.doInitialize();
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).deprecateLendingProtocols(lendingProtocols);
        uint256 balance = this.getSuppliedBalance(address(aaveProtocol), address(mainnet.WETH));
        assertEq(balance, 0);
    }

    function test_RebalanceFromCheck_AllowsNonVaultAssetWhenVaultHoldsBalance() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        MockERC20 stable = new MockERC20("Stable", "STB", 6);

        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).addStableCoins(_single(address(stable)));
        BittyV1Guard(guardAddress).addAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        address[] memory initAssets = new address[](5);
        initAssets[0] = mainnet.WETH;
        initAssets[1] = WBTC;
        initAssets[2] = mainnet.USDT;
        initAssets[3] = mainnet.USDC;
        initAssets[4] = address(stable);

        this.initialize(
            ownerAddress,
            guardAddress,
            mainnet.WETH,
            initAssets,
            lendingProtocols,
            stakingProtocols,
            _single(address(mockAmm)),
            intentProtocols,
            address(0),
            RiskControlLevel.Zero
        );
        _grantAssetManagerRole(assetManagerAddress);
        _cloneProtocolForTest(address(mockAmm));

        stray.mint(address(this), 10 ether);

        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = 100e6;

        vm.prank(assetManagerAddress);
        bytes32 id =
            this.limitSell(address(mockIntent), address(stray), address(stable), sellAmount, buyAmountMin, _validTo());
        assertTrue(id != bytes32(0));
    }

    function test_RebalanceFromCheck_MinimalBalanceNotMet_WhenRemainingBelowMinimal() public {
        this.doInitialize();

        uint256 minimalBalance = 100 ether;
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, minimalBalance);

        uint256 fromBalance = 1000 ether;
        uint256 sellAmount = 950 ether;

        deal(address(mainnet.WETH), address(this), fromBalance);

        uint256 buyAmount = 10 * 1e6;

        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManagerAddress);
        this.limitSell(
            address(mockIntent), address(mainnet.WETH), address(mainnet.USDT), sellAmount, buyAmount, _validTo()
        );
    }

    function test_MinimalBalance_CountsSuppliedPosition() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 10 ether);

        // Supply 8 WETH to Aave → spot 2, supplied ~8, total ~10.
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, 8 ether);

        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, 4 ether);

        uint256 sellAmount = 1 ether;
        uint256 buyAmountMin = 1;

        // Spot alone (2 → 1 after the sell) is below the 4-WETH floor, so spot-only accounting would
        // revert MinimalBalanceNotMet; counting the ~8 supplied lets the total clear the floor.
        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, _validTo());
    }

    function test_RebalanceFromCheck_MinimalBalanceNotMet_WhenSellExceedsBalance() public {
        this.doInitialize();

        uint256 minimalBalance = 100 ether;
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, minimalBalance);

        uint256 fromBalance = 50 ether;
        uint256 sellAmount = 100 ether;

        deal(address(mainnet.WETH), address(this), fromBalance);

        uint256 buyAmount = 10 * 1e6;

        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManagerAddress);
        this.limitSell(
            address(mockIntent), address(mainnet.WETH), address(mainnet.USDT), sellAmount, buyAmount, _validTo()
        );
    }

    function test_RebalanceFromCheck_MinimalBalance_SucceedsWhenRemainingAtLeastMinimal() public {
        this.doInitialize();

        uint256 minimalBalance = 4 ether;
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, minimalBalance);

        uint256 fromBalance = 10 ether;
        uint256 sellAmount = 5 ether;

        deal(mainnet.WETH, address(this), fromBalance);
        uint256 buyAmountMin = 1;

        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, _validTo());
    }

    function test_SetTradeLimit_RevertsForNonOwner() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, DEFAULT_ADMIN_ROLE));
        this.setAssetManager(assetManagerAddress, 1 hours, 1000, 0, 0);
    }

    function test_SetTradeLimit_RevertsAddressZero() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        vm.expectRevert(AddressZero.selector);
        this.setAssetManager(address(0), 1 hours, 1000, 0, 0);
    }

    function test_SetTradeLimit_RevertsWhenCapZero() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        vm.expectRevert(StableCoinInvestCapZero.selector);
        this.setAssetManager(assetManagerAddress, 0, 0, 0, 0);
    }

    function test_AddAssetManager_RevertsWhenCapZero() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        vm.expectRevert(StableCoinInvestCapZero.selector);
        this.setAssetManager(makeAddr("newAssetManager"), 0, 0, 0, 0);
    }

    function test_SetAssetManager_ReplacesAndRemoveClears() public {
        this.doInitialize();
        address assetManager = makeAddr("removableAssetManager");
        vm.prank(ownerAddress);
        this.setAssetManager(assetManager, 1 hours, 1000, 5_000, 0);
        assertEq(this.getAssetManager(), assetManager);
        assertEq(this.getSettingsInvestedBudget(assetManager), 5_000);

        vm.prank(ownerAddress);
        this.removeAssetManager();
        assertEq(this.getAssetManager(), address(0));
        assertEq(this.getSettingsInvestedBudget(assetManager), 0);
    }

    function test_TradeLimit_SizeCap_RevertsWhenStableLegExceeds() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 10 ether);

        // Cap the stablecoin leg to 1,000 whole USDT (6 decimals → 1_000e6 raw units).
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, 0, 1000, type(uint64).max, 0);

        // USDT is the buy leg; the declared floor (1_001e6) exceeds the 1_000e6 cap.
        uint256 buyAmountMin = 1_001 * 1e6;

        vm.expectRevert(TradeSizeExceeded.selector);
        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, 1 ether, buyAmountMin, _validTo());
    }

    function test_TradeLimit_SizeCap_SucceedsWhenStableLegUnderCap() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 10 ether);

        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, 0, 1000, type(uint64).max, 0);

        uint256 sellAmount = 0.01 ether;
        uint256 buyAmountMin = 1;

        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, _validTo());
    }

    function test_TradeLimit_SizeCap_RevertsWhenNeitherLegStable() public {
        this.doInitialize();

        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, 0, 1000, type(uint64).max, 0);

        // WETH → WBTC: neither token is a stablecoin, so the size is not measurable in dollars.
        vm.expectRevert(TradeMustTouchStableCoin.selector);
        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, WBTC, 1 ether, 1, _validTo());
    }

    function test_TradeLimit_Interval_ThrottlesSecondTrade() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 10 ether);

        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, 1 hours, 0, type(uint64).max, 0);

        uint256 sellAmount = 0.01 ether;

        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, sellAmount, 1, _validTo());

        vm.expectRevert(TradeInInterval.selector);
        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, sellAmount, 1, _validTo());

        vm.warp(block.timestamp + 1 hours);
        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, sellAmount, 1, _validTo());
    }

    function test_SetAssetManager_ReplacesPreviousAssetManager() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 10 ether);

        // Setting a new asset manager replaces the previous one — the old one can no longer trade.
        vm.prank(ownerAddress);
        this.setAssetManager(makeAddr("otherAssetManager"), 1 hours, 1, type(uint64).max, 0);

        uint256 sellAmount = 0.01 ether;
        vm.prank(assetManagerAddress);
        vm.expectRevert(NotAssetManager.selector);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, sellAmount, 1, _validTo());
    }

    function test_TradeLimit_ExpiredAt_RevertsAfterExpiry() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);

        uint256 expiry = block.timestamp + 1 hours;
        _setTradeLimit(assetManagerAddress, 0, 0, type(uint64).max, expiry);

        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, 0.01 ether, 1, _validTo());

        vm.warp(expiry);
        vm.expectRevert(TradeLimitExpired.selector);
        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, 0.01 ether, 1, _validTo());
    }

    function test_TradeLimit_InvestedTotal_RevertsWhenBuyingWithStableExceedsBudget() public {
        this.doInitialize();
        deal(mainnet.USDT, address(this), 2_000 * 1e6);

        _setTradeLimit(assetManagerAddress, 0, 0, 1_000, 0);

        vm.expectRevert(TradeInvestedTotalExceeded.selector);
        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.USDT, mainnet.WETH, 1_001 * 1e6, 1, _validTo());
    }

    function test_TradeLimit_InvestedTotal_SubTokenTradeCountsAsWholeToken() public {
        this.doInitialize();
        deal(mainnet.USDT, address(this), 2_000 * 1e6);
        _setTradeLimit(assetManagerAddress, 0, 0, 1_000, 0);

        // A sub-whole-token invest (0.5 USDT) must round UP to 1, not floor to 0 — otherwise a stream of
        // dust trades could deploy capital past the cap for free.
        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.USDT, mainnet.WETH, 500_000, 1, _validTo());
        assertEq(this.getSettingsInvestedBudget(assetManagerAddress), 1_000 - 1);
    }

    function test_FullAccess_SkipsInvestCapAndTracking() public {
        this.doInitialize();
        _setTradeLimit(assetManagerAddress, 0, 0, 1_000, 0); // start restricted with a small cap
        vm.prank(ownerAddress);
        this.setFullAssetManager(assetManagerAddress); // upgrade to full-access

        deal(mainnet.USDT, address(this), 5_000 * 1e6);
        // Investing 2,000 USDT would exceed the 1,000 cap — full-access ignores it and does not track.
        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.USDT, mainnet.WETH, 2_000 * 1e6, 1, _validTo());
        assertEq(this.getSettingsInvested(assetManagerAddress), 0, "invested not tracked for full-access");
    }

    function test_FullAccess_MinimalBalanceStillEnforced() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setFullAssetManager(assetManagerAddress);

        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, 0.5 ether);

        // Selling below the minimal-balance floor reverts even for a full-access asset manager.
        vm.prank(assetManagerAddress);
        vm.expectRevert(MinimalBalanceNotMet.selector);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, 0.6 ether, 1, _validTo());
    }

    function test_SetTradeLimit_DemotesFullAccessToRestricted() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setFullAssetManager(assetManagerAddress);
        _setTradeLimit(assetManagerAddress, 0, 0, 1_000, 0); // restrict again

        deal(mainnet.USDT, address(this), 5_000 * 1e6);
        // The cap is enforced again: investing 1,001 USDT reverts.
        vm.prank(assetManagerAddress);
        vm.expectRevert(TradeInvestedTotalExceeded.selector);
        this.limitSell(address(mockIntent), mainnet.USDT, mainnet.WETH, 1_001 * 1e6, 1, _validTo());
    }

    function test_InvestCap_RefundedWhenUnfilledLimitOrderCancelled() public {
        this.doInitialize();
        _setTradeLimit(assetManagerAddress, 0, 0, 1_000, 0);
        deal(mainnet.USDT, address(this), 5_000 * 1e6);

        bytes32 id = this.limitSell(address(mockIntent), mainnet.USDT, mainnet.WETH, 600 * 1e6, 1, _validTo());
        assertEq(this.getSettingsInvested(assetManagerAddress), 600, "placement counts the invest");

        // Never filled: cancelling reclaims the whole reserved budget (fill-or-kill → nothing deployed).
        this.cancelLimitOrder(address(mockIntent), abi.encode(id));
        assertEq(this.getSettingsInvested(assetManagerAddress), 0, "unfilled cancel refunds the invest budget");
    }

    function test_InvestCap_NotRefundedWhenFilledOrderCancelled() public {
        this.doInitialize();
        _setTradeLimit(assetManagerAddress, 0, 0, 1_000, 0);
        deal(mainnet.USDT, address(this), 5_000 * 1e6);

        bytes32 id = this.limitSell(address(mockIntent), mainnet.USDT, mainnet.WETH, 600 * 1e6, 1, _validTo());
        intentRegistry.setFilled(id, true); // the order settled on-chain

        // A filled order actually deployed the stablecoin, so its budget stays counted after cancel.
        this.cancelLimitOrder(address(mockIntent), abi.encode(id));
        assertEq(this.getSettingsInvested(assetManagerAddress), 600, "filled deployment stays counted");
    }

    function test_InvestCap_RefundedOnExpiredCleanup() public {
        this.doInitialize();
        _setTradeLimit(assetManagerAddress, 0, 0, 1_000, 0);
        deal(mainnet.USDT, address(this), 5_000 * 1e6);

        uint32 vt = _validTo();
        bytes32 id = this.limitSell(address(mockIntent), mainnet.USDT, mainnet.WETH, 600 * 1e6, 1, vt);
        assertEq(this.getSettingsInvested(assetManagerAddress), 600);

        vm.warp(uint256(vt) + 1);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        this.cleanExpiredLimitOrders(address(mockIntent), ids);
        assertEq(this.getSettingsInvested(assetManagerAddress), 0, "expired-unfilled cleanup refunds too");
    }

    function test_TradeLimit_ZeroInterval_SkipsLastTradeTimestampWrite() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 10 ether);

        _setTradeLimit(assetManagerAddress, 0, 0, type(uint64).max, 0);
        assertEq(this.getSettingsLastTradeTimestamp(assetManagerAddress), 0);

        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, 0.01 ether, 1, _validTo());
        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, 0.01 ether, 1, _validTo());

        assertEq(this.getSettingsLastTradeTimestamp(assetManagerAddress), 0);
    }

    function test_TradeLimit_NonZeroInterval_RecordsLastTradeTimestamp() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 10 ether);

        _setTradeLimit(assetManagerAddress, 1 hours, 0, type(uint64).max, 0);
        assertEq(this.getSettingsLastTradeTimestamp(assetManagerAddress), 0);

        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, 0.01 ether, 1, _validTo());

        assertEq(this.getSettingsLastTradeTimestamp(assetManagerAddress), block.timestamp);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_RevertsWhenBeforeTimestamp() public {
        this.doInitialize();

        uint256 disabledUntil = block.timestamp + 100;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(disabledUntil);

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), sellAmount);
        uint256 buyAmountMin = 1;

        vm.expectRevert(RebalanceDisabled.selector);
        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, _validTo());
    }

    function test_CheckRebalanceDisabledUntilTimestamp_SucceedsAfterTimestamp() public {
        this.doInitialize();

        uint256 disabledUntil = block.timestamp + 100;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(disabledUntil);

        vm.warp(disabledUntil + 1);

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), sellAmount);
        uint256 buyAmountMin = 1;

        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, _validTo());
    }

    function test_CheckRebalanceDisabledUntilTimestamp_SucceedsWhenNeverDisabled() public {
        this.doInitialize();

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), sellAmount);
        uint256 buyAmountMin = 1;

        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, _validTo());
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

    function test_DisableRebalanceUntilTimestamp_AllowsExactlyFourYears() public {
        this.doInitialize();

        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(block.timestamp + 4 * 365 days);
    }

    function test_DisableRebalanceUntilTimestamp_RevertsBeyondFourYears() public {
        this.doInitialize();

        vm.expectRevert(DisableRebalanceUntilTimestampTooLong.selector);
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(block.timestamp + 4 * 365 days + 1);
    }

    function test_DisableAddingAssets_RevertsWhenNotOwnerOrAssetManager() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, DEFAULT_ADMIN_ROLE));
        this.disableAddingAssets();
    }

    function test_AddAssets_afterInit_addsStableCoinViaUnifiedPath() public {
        this.initialize(
            ownerAddress,
            guardAddress,
            mainnet.WETH,
            assets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            address(0),
            RiskControlLevel.Zero
        );
        _grantAssetManagerRole(assetManagerAddress);

        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(usdc);

        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addStableCoins(toAdd);

        vm.prank(ownerAddress);
        this.addAssets(toAdd);

        assertEq(this.getStableCoins().length, 1);
        assertEq(this.getStableCoins()[0], address(usdc));
        assertEq(this.getAssets().length, 2);
    }

    function test_DisableAddingAssets_SucceedsAndAddAssetsReverts() public {
        this.doInitialize();

        MockERC20 mockDAI = new MockERC20("DAI", "DAI", 18);
        address[] memory newAssets = new address[](1);
        newAssets[0] = address(mockDAI);
        vm.prank(ownerAddress);
        BittyV1Guard(guardAddress).addAssets(newAssets);

        vm.prank(ownerAddress);
        this.disableAddingAssets();

        vm.expectRevert(AddingAssetsDisabled.selector);
        vm.prank(ownerAddress);
        this.addAssets(newAssets);
    }

    function test_StakeRevertOnlyAssetManager() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        address stranger = makeAddr("subscribedStranger");
        vm.prank(stranger);
        vm.expectRevert(NotAssetManager.selector);
        this.stake(address(lidoProtocol), mainnet.WETH, 1 ether);
    }

    function test_StakeRevertInvalidStakingProtocol() public {
        this.doInitialize();
        address invalidStakingProvider = makeAddr("InvalidStakingProtocol");
        vm.expectRevert(InvalidStakingProtocol.selector);
        vm.prank(assetManagerAddress);
        this.stake(invalidStakingProvider, mainnet.WETH, 1 ether);
    }

    function test_StakeRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, 0);
    }

    function test_StakeSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        assertEq(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), 0);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        address clonedProtocol = this.getClonedProvider(address(lidoProtocol));
        assertTrue(clonedProtocol != address(0));
        assertApproxEqAbs(IBittyV1StakingProtocol(clonedProtocol).getStakedBalance(mainnet.WETH), stakeAmount, 10);
        assertApproxEqAbs(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), stakeAmount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_GetStakingBalance() public {
        this.doInitialize();
        assertEq(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), 0);

        uint256 stakeAmount = 2 ether;
        deal(mainnet.WETH, address(this), stakeAmount);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        assertApproxEqAbs(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), stakeAmount, 10);
    }

    function test_GetStakingBalance_UnusedStakingProtocol_ReturnsZero() public {
        this.doInitialize();
        assertEq(this.getStakedBalance(makeAddr("UnusedStakingProtocol"), mainnet.WETH), 0);
    }

    function test_UnstakeSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 1 ether;
        uint256 unstakeAmount = 0.5 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);
        assertApproxEqAbs(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), stakeAmount, 10);

        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProtocol), mainnet.WETH, unstakeAmount);
        assertApproxEqAbs(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), stakeAmount - unstakeAmount, 10);

        uint256[] memory requestIds = this.getUnstakeRequestIds(address(lidoProtocol));
        assertEq(requestIds.length, 1);

        vm.prank(assetManagerAddress);
        this.claimUnstaked(address(lidoProtocol), requestIds);
    }

    function test_ClaimSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 0.1 ether;
        uint256 unstakeAmount = 0.05 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);
        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProtocol), mainnet.WETH, unstakeAmount);

        uint256[] memory requestIds = this.getUnstakeRequestIds(address(lidoProtocol));
        assertEq(requestIds.length, 1);

        vm.prank(assetManagerAddress);
        this.claimUnstaked(address(lidoProtocol), requestIds);
        // Lido withdrawals are not finalized immediately on a mainnet fork.
        assertEq(this.getUnstakeRequestIds(address(lidoProtocol)).length, 1);
    }

    function test_ClaimRevertOnlyAssetManager() public {
        this.doInitialize();
        uint256[] memory requestIds = new uint256[](0);
        address stranger = makeAddr("subscribedStranger");
        vm.prank(stranger);
        vm.expectRevert(NotAssetManager.selector);
        this.claimUnstaked(address(lidoProtocol), requestIds);
    }

    function test_RemoveLiquidityWorksAfterAMMProtocolRemoved() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);

        vm.prank(ownerAddress);
        this.removeAMMProtocols(_single(address(mockAmm)));

        bytes memory data = abi.encode(uint256(9));
        vm.prank(assetManagerAddress);
        this.removeLiquidity(address(mockAmm), data);

        address clone = this.getClonedProvider(address(mockAmm));
        assertEq(MockAMMProtocol(clone).removeLiquidityCallCount(), 1);
        assertEq(MockAMMProtocol(clone).lastRemoveData(), data);
    }

    function test_ClaimEmptyRequestIds_doesNotRevert() public {
        this.doInitialize();
        uint256[] memory requestIds = new uint256[](0);
        vm.prank(assetManagerAddress);
        this.claimUnstaked(address(lidoProtocol), requestIds);
    }

    function test_UnstakeRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProtocol), mainnet.WETH, 0);
    }

    function test_UnstakeWorksAfterStakingProtocolRemoved() public {
        this.doInitialize();
        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, amount);

        vm.prank(ownerAddress);
        this.removeStakingProtocols(_single(address(lidoProtocol)));

        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProtocol), mainnet.WETH, amount / 2);

        uint256[] memory ids =
            IBittyV1StakingProtocol(this.getClonedProvider(address(lidoProtocol))).getUnstakeRequestIds();
        assertEq(ids.length, 1, "unstake request created after removal");
    }

    function test_GetUnstakeRequestIds() public {
        this.doInitialize();
        uint256[] memory ids = this.getUnstakeRequestIds(address(lidoProtocol));
        assertEq(ids.length, 0);

        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, 1 ether);
        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProtocol), mainnet.WETH, 0.5 ether);

        ids = this.getUnstakeRequestIds(address(lidoProtocol));
        assertEq(ids.length, 1);
    }

    function test_GetUnstakeRequestIds_UnusedStakingProtocol_ReturnsEmpty() public {
        this.doInitialize();
        assertEq(this.getUnstakeRequestIds(makeAddr("UnusedStakingProtocol")).length, 0);
    }

    function test_SupplyAllowanceIsMaxAfterFirstApproval() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount * 2);

        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        assertEq(
            IERC20(mainnet.WETH).allowance(address(this), clonedProtocol),
            type(uint256).max,
            "Allowance should be max after first supply"
        );

        // Second supply must not revert — allowance guard skips re-approval when allowance >= amount
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);
    }

    function test_SupplySucceedsWithPreExistingResidualAllowance() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount);

        address clonedProtocol = _cloneProtocolForTest(address(aaveProtocol));

        IERC20(mainnet.WETH).approve(clonedProtocol, 1);
        assertEq(IERC20(mainnet.WETH).allowance(address(this), clonedProtocol), 1);

        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);

        assertApproxEqAbs(IBittyV1LendingProtocol(clonedProtocol).getSuppliedBalance(mainnet.WETH), supplyAmount, 10);
    }

    // ─── AMM: deprecated protocol and decreaseLiquidity ───────────────────────

    function test_AddLiquidityRevertDeprecatedAMMProtocol() public {
        this.doInitialize();
        _deprecateVaultAMMProtocols();
        vm.expectRevert(Deprecated.selector);
        vm.prank(assetManagerAddress);
        this.addLiquidity(address(uniswapV3Protocol), mainnet.WETH, 0, mainnet.USDT, 0, "");
    }

    function test_DecreaseLiquiditySuccess() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address clone = this.getClonedProvider(address(mockAmm));
        bytes memory data = abi.encode(uint256(1));

        vm.prank(assetManagerAddress);
        this.decreaseLiquidity(address(mockAmm), data);

        assertEq(MockAMMProtocol(clone).decreaseLiquidityCallCount(), 1);
        assertEq(MockAMMProtocol(clone).lastDecreaseData(), data);
    }

    function test_DecreaseLiquiditySuccessOnDeprecatedAMMProtocol() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address clone = this.getClonedProvider(address(mockAmm));
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).deprecateAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        bytes memory data = abi.encode(uint256(42));
        vm.prank(assetManagerAddress);
        this.decreaseLiquidity(address(mockAmm), data);

        assertEq(MockAMMProtocol(clone).decreaseLiquidityCallCount(), 1);
        assertEq(MockAMMProtocol(clone).lastDecreaseData(), data);
    }

    function test_RemoveLiquiditySuccessOnDeprecatedAMMProtocol() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address clone = this.getClonedProvider(address(mockAmm));
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).deprecateAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        bytes memory data = abi.encode(uint256(7));
        vm.prank(assetManagerAddress);
        this.removeLiquidity(address(mockAmm), data);

        assertEq(MockAMMProtocol(clone).removeLiquidityCallCount(), 1);
        assertEq(MockAMMProtocol(clone).lastRemoveData(), data);
    }

    function _initWithMockAMMNoClone(MockAMMProtocol mockAmm) internal {
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).addAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        this.initialize(
            ownerAddress,
            guardAddress,
            mainnet.WETH,
            vaultAssets,
            lendingProtocols,
            stakingProtocols,
            _single(address(mockAmm)),
            intentProtocols,
            address(0),
            RiskControlLevel.Zero
        );
        _grantAssetManagerRole(assetManagerAddress);
    }

    function test_AddLiquidity_ClonesOnFirstUse() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initWithMockAMMNoClone(mockAmm);
        assertEq(this.getClonedProvider(address(mockAmm)), address(0), "no clone before first use");

        vm.prank(assetManagerAddress);
        this.addLiquidity(address(mockAmm), mainnet.WETH, 0, mainnet.USDT, 0, "");

        assertTrue(this.getClonedProvider(address(mockAmm)) != address(0), "addLiquidity must clone on first use");
    }

    // Both tokens deployed into an LP must be registered vault assets — otherwise addLiquidity is a path
    // to move unregistered tokens out around the asset allowlist.
    function test_AddLiquidity_RejectsUnregisteredToken0() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address unregistered = makeAddr("unregisteredToken");
        vm.prank(assetManagerAddress);
        vm.expectRevert(NotRegistered.selector);
        this.addLiquidity(address(mockAmm), unregistered, 1 ether, mainnet.USDT, 0, "");
    }

    function test_AddLiquidity_RejectsUnregisteredToken1() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address unregistered = makeAddr("unregisteredToken");
        vm.prank(assetManagerAddress);
        vm.expectRevert(NotRegistered.selector);
        this.addLiquidity(address(mockAmm), mainnet.WETH, 1 ether, unregistered, 1 ether, "");
    }

    // An add with both tokens registered is allowed.
    function test_AddLiquidity_SucceedsWithRegisteredTokens() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        deal(mainnet.WETH, address(this), 1000 ether);

        vm.prank(assetManagerAddress);
        this.addLiquidity(address(mockAmm), mainnet.WETH, 800 ether, mainnet.USDT, 0, "");
    }

    function test_RemoveLiquidity_RevertsWithoutClone() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initWithMockAMMNoClone(mockAmm);
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidAMMProtocol.selector);
        this.removeLiquidity(address(mockAmm), abi.encode(uint256(7)));
    }

    function test_DecreaseLiquidity_RevertsWithoutClone() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initWithMockAMMNoClone(mockAmm);
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidAMMProtocol.selector);
        this.decreaseLiquidity(address(mockAmm), abi.encode(uint256(3)));
    }

    function test_ClaimAMMFees_RevertsWithoutClone() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initWithMockAMMNoClone(mockAmm);
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidAMMProtocol.selector);
        this.claimAMMFees(address(mockAmm), "");
    }

    function test_ExitOps_RejectArbitraryUnregisteredProtocol() public {
        this.doInitialize();
        address attacker = makeAddr("maliciousProtocol");

        vm.startPrank(assetManagerAddress);
        vm.expectRevert(InvalidAMMProtocol.selector);
        this.removeLiquidity(attacker, abi.encode(uint256(1)));
        vm.expectRevert(InvalidLendingProtocol.selector);
        this.withdraw(attacker, mainnet.WETH, 1 ether);
        vm.expectRevert(InvalidStakingProtocol.selector);
        this.unstake(attacker, mainnet.WETH, 1 ether);
        vm.stopPrank();
    }

    function test_DecreaseLiquidityRevertOnlyAssetManager() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(NotAssetManager.selector);
        this.decreaseLiquidity(address(mockAmm), "");
    }

    function test_GetLiquidityFromDeprecatedAMMProtocol() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).deprecateAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        assertEq(this.getLiquidity(address(mockAmm), ""), 0);
    }

    // ─── Fuzz Tests ───────────────────────────────────────────────────────────

    function testFuzz_SetMinimalBalance_anyValueAccepted(uint256 minimalBalance) public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, minimalBalance);
    }

    function testFuzz_RebalanceMinimalBalance_revertsWhenRemainingBelowMin(
        uint256 minimalBalance,
        uint256 fromBalance,
        uint256 sellAmount
    ) public {
        minimalBalance = bound(minimalBalance, 1 ether, 100 ether);
        fromBalance = bound(fromBalance, minimalBalance, minimalBalance + 100 ether);
        sellAmount = bound(sellAmount, fromBalance - minimalBalance + 1, fromBalance);
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, minimalBalance);
        deal(mainnet.WETH, address(this), fromBalance);
        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManagerAddress);
        this.limitSell(address(mockIntent), mainnet.WETH, mainnet.USDT, sellAmount, 1, _validTo());
    }

    function testFuzz_DisableRebalanceUntilTimestamp_cannotMovePrevTimestampEarlier(uint256 offset, uint256 reduction)
        public
    {
        offset = bound(offset, 2, 4 * 365 days);
        reduction = bound(reduction, 1, offset);
        this.doInitialize();
        uint256 first = block.timestamp + offset;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(first);
        vm.expectRevert(DisableRebalanceUntilTimestampTooEarly.selector);
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(first - reduction);
    }

    function test_StakeSucceedsWithPreExistingResidualAllowance() public {
        this.doInitialize();

        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        address clonedProtocol = _cloneProtocolForTest(address(lidoProtocol));

        IERC20(mainnet.WETH).approve(clonedProtocol, 1);
        assertEq(IERC20(mainnet.WETH).allowance(address(this), clonedProtocol), 1);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        assertApproxEqAbs(IBittyV1StakingProtocol(clonedProtocol).getStakedBalance(mainnet.WETH), stakeAmount, 10);
    }

    // ============ Auto yield ============

    function test_SetAutoYieldingRevertNotOwner() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.expectRevert(_roleError(stranger, DEFAULT_ADMIN_ROLE));
        vm.prank(stranger);
        this.setAutoYielding(mainnet.WETH, address(aaveProtocol), true);
    }

    function test_SetAutoYieldingRevertAssetAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(ownerAddress);
        this.setAutoYielding(address(0), address(aaveProtocol), true);
    }

    function test_SetAutoYieldingRevertUnregisteredLendingProtocol() public {
        this.doInitialize();
        // A staking protocol is not a valid supply route (and vice versa below).
        vm.expectRevert(InvalidLendingProtocol.selector);
        vm.prank(ownerAddress);
        this.setAutoYielding(mainnet.WETH, address(lidoProtocol), true);
    }

    function test_SetAutoYieldingRevertUnregisteredStakingProtocol() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProtocol.selector);
        vm.prank(ownerAddress);
        this.setAutoYielding(mainnet.WETH, address(aaveProtocol), false);
    }

    function test_SetAndGetAutoYielding() public {
        this.doInitialize();
        (address protocol, bool isSupplying) = this.getAutoYielding(mainnet.WETH);
        assertEq(protocol, address(0));

        vm.prank(ownerAddress);
        this.setAutoYielding(mainnet.WETH, address(aaveProtocol), true);
        (protocol, isSupplying) = this.getAutoYielding(mainnet.WETH);
        assertEq(protocol, address(aaveProtocol));
        assertTrue(isSupplying);

        vm.prank(ownerAddress);
        this.setAutoYielding(mainnet.WETH, address(0), true);
        (protocol,) = this.getAutoYielding(mainnet.WETH);
        assertEq(protocol, address(0));
    }

    // Sends native ETH to the vault, triggering receive() → wrap to WETH → auto-yield.
    // Clears any WETH the harness setup left behind first so the deposit is the only source.
    function _depositEth(uint256 amount) internal {
        deal(mainnet.WETH, address(this), 0);
        vm.deal(address(this), amount);
        (bool ok,) = address(this).call{value: amount}("");
        assertTrue(ok, "eth deposit failed");
    }

    function test_AutoYieldRevertNotTrigger() public {
        this.doInitialize();
        // Auto-yield is not permissionless: an unauthorized caller is rejected.
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(NotAutoYieldTrigger.selector);
        this.autoYield(mainnet.WETH);
    }

    function test_AutoYieldTriggerCanSweep() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYielding(mainnet.WETH, address(aaveProtocol), true);
        address keeper = makeAddr("keeper");
        vm.prank(ownerAddress);
        this.setAutoYieldTrigger(keeper);
        assertEq(this.getAutoYieldTrigger(), keeper);

        // The vault holds WETH (not from an ETH deposit) — the trigger sweeps it into the route.
        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(keeper);
        this.autoYield(mainnet.WETH);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        assertApproxEqAbs(IBittyV1LendingProtocol(clonedProtocol).getSuppliedBalance(mainnet.WETH), 1 ether, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_AutoYieldTriggerClearedRevokesAccess() public {
        this.doInitialize();
        address keeper = makeAddr("keeper");
        vm.prank(ownerAddress);
        this.setAutoYieldTrigger(keeper);
        vm.prank(ownerAddress);
        this.setAutoYieldTrigger(address(0));

        vm.prank(keeper);
        vm.expectRevert(NotAutoYieldTrigger.selector);
        this.autoYield(mainnet.WETH);
    }

    function test_AutoYieldNoRouteKeepsWeth() public {
        this.doInitialize();
        _depositEth(1 ether);
        // No route configured → the deposit is wrapped but stays liquid in the vault.
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 1 ether);
    }

    function test_AutoYieldSupplyOnDeposit() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYielding(mainnet.WETH, address(aaveProtocol), true);

        _depositEth(1 ether);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        assertApproxEqAbs(IBittyV1LendingProtocol(clonedProtocol).getSuppliedBalance(mainnet.WETH), 1 ether, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_AutoYieldStakeOnDeposit() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYielding(mainnet.WETH, address(lidoProtocol), false);

        _depositEth(0.5 ether);

        assertApproxEqAbs(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), 0.5 ether, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_AutoYieldKeepsMinimalBalanceLiquid() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYielding(mainnet.WETH, address(lidoProtocol), false);
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, 0.3 ether);

        _depositEth(1 ether);
        assertApproxEqAbs(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), 0.7 ether, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0.3 ether);
    }

    function test_AutoYieldNothingSpendableKeepsWeth() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYielding(mainnet.WETH, address(lidoProtocol), false);
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, 1 ether);

        // Whole deposit sits at the liquid floor → nothing yielded, all WETH stays.
        _depositEth(1 ether);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 1 ether);
        assertEq(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), 0);
    }

    function test_AutoYieldSkippedAfterProtocolRemoved() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYielding(mainnet.WETH, address(lidoProtocol), false);
        vm.prank(ownerAddress);
        this.removeStakingProtocols(stakingProtocols);

        // Route now invalid → auto-yield is a caught no-op; the deposit still succeeds.
        _depositEth(1 ether);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 1 ether);
    }

    function test_AutoYieldSkippedForDeprecatedProtocol() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYielding(mainnet.WETH, address(lidoProtocol), false);
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).deprecateStakingProtocols(stakingProtocols);

        _depositEth(1 ether);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 1 ether);
    }
}
