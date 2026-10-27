// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockChargeWindow} from "../helpers/MockChargeWindow.sol";
import {MockFeed} from "./MarketTradeGuard.t.sol";
import {PriceStale, SequencerDown} from "../../src/interfaces/IBittyV1DeFi.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {
    NotTrustedForwarder,
    GasBudgetExceeded,
    GasBudgetTooHigh,
    FeeExceedsPerOpCap,
    InvalidAsset,
    AmountIsZero
} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    BITTY_GUARD,
    BITTY_FORWARDER,
    BITTY_FEE_COLLECTOR,
    SYSTEM_DAILY_MAX_GAS_BUDGET,
    SYSTEM_MAX_FEE_PER_OP
} from "../../src/logic/Constants.sol";

/**
 * The main vault paying its own relayed gas, in stable coin or the vault's WETH.
 *
 * Two ceilings bound what a relayer can take — a per-charge cap and a per-day budget — and the vault
 * enforces both itself, so a compromised relayer can overcharge by a bounded amount and never more.
 */
contract VaultTokenAsGasTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 other;

    address owner = makeAddr("owner");
    MockERC20 weth;
    MockFeed wethFeed;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        address gasWrapped = address(weth);
        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        other = new MockERC20("Other", "OTH", 18);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 1_000_000e6);
        other.mint(address(vault), 1_000e18);
        weth.mint(address(vault), 10e18);
        wethFeed = new MockFeed();
        wethFeed.set(2_000e8, block.timestamp, block.timestamp);
        guard.setPriceFeed(address(weth), address(wethFeed), 1 hours, address(0));

        // The charge asks the forwarder whether it is settling for this vault; these tests charge it
        // directly, so the window is held open for the whole file. See {MockChargeWindow}.
        vm.etch(BITTY_FORWARDER, address(new MockChargeWindow()).code);
        MockChargeWindow(BITTY_FORWARDER).setChargingVault(address(vault));
    }

    function _charge(address asset, uint256 amount) internal {
        vm.prank(BITTY_FORWARDER);
        vault.payRelayerFee(asset, amount);
    }

    // ── who may charge ────────────────────────────────────────────────────────

    /// Only the forwarder. Otherwise anyone could drain the day's budget to the collector.
    function test_onlyTheForwarderMayCharge() public {
        vm.prank(owner);
        vm.expectRevert(NotTrustedForwarder.selector);
        vault.payRelayerFee(address(usdc), 1e6);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotTrustedForwarder.selector);
        vault.payRelayerFee(address(usdc), 1e6);
    }

    // ── defaults ──────────────────────────────────────────────────────────────

    /**
     * A vault that never called setTokenAsGas is relayable, at the system defaults, in any stable coin
     * the guard registers. An empty list means "anything permitted", not "nothing" — read the other
     * way, stablecoin fee payments would be off for every fresh vault while gasBudgetRemaining reported a full day.
     */
    function test_freshVaultIsRelayableAtSystemDefaults() public {
        (address[] memory assets, uint256 daily, uint256 perOp) = vault.tokenAsGasConfig();
        assertEq(assets.length, 0, "nothing narrowed");
        assertEq(daily, SYSTEM_DAILY_MAX_GAS_BUDGET);
        assertEq(perOp, SYSTEM_MAX_FEE_PER_OP);
        assertEq(vault.gasBudgetRemaining(), uint256(SYSTEM_DAILY_MAX_GAS_BUDGET) * 1e18);

        _charge(address(usdc), 2e6);
        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 2e6, "charged without any setup");
    }

    /// An asset the guard does not register cannot pay, even on the permissive default.
    function test_unregisteredAssetCannotPay() public {
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(InvalidAsset.selector);
        vault.payRelayerFee(address(other), 1e18);
    }

    // ── narrowing ─────────────────────────────────────────────────────────────

    function test_ownerNarrowsToNamedCoins() public {
        guard.setAsset(address(other), ASSET_STABLE_COIN);
        address[] memory only = new address[](1);
        only[0] = address(usdc);

        vm.prank(owner);
        vault.setTokenAsGas(only, 50, 5);

        (address[] memory assets, uint256 daily, uint256 perOp) = vault.tokenAsGasConfig();
        assertEq(assets.length, 1, "narrowed to one");
        assertEq(assets[0], address(usdc));
        assertEq(daily, 50);
        assertEq(perOp, 5);

        _charge(address(usdc), 1e6);
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(InvalidAsset.selector);
        vault.payRelayerFee(address(other), 1e18); // registered, but not named
    }

    /// The owner's own ceilings cannot exceed the system's.
    function test_ownerCannotRaiseAboveTheSystemCeilings() public {
        address[] memory none = new address[](0);
        vm.startPrank(owner);
        vm.expectRevert(GasBudgetTooHigh.selector);
        vault.setTokenAsGas(none, SYSTEM_DAILY_MAX_GAS_BUDGET + 1, 1);
        vm.expectRevert(FeeExceedsPerOpCap.selector);
        vault.setTokenAsGas(none, 1, SYSTEM_MAX_FEE_PER_OP + 1);
        vm.stopPrank();
    }

    // ── the two ceilings ──────────────────────────────────────────────────────

    /// Per charge: one oversized fee is refused outright rather than clamped.
    function test_perOpCapBoundsASingleCharge() public {
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(FeeExceedsPerOpCap.selector);
        vault.payRelayerFee(address(usdc), (uint256(SYSTEM_MAX_FEE_PER_OP) + 1) * 1e6);
    }

    /// Per day: charges accumulate, and the budget is what stops the tenth one.
    function test_dailyBudgetAccumulatesAndThenRefuses() public {
        address[] memory none = new address[](0);
        vm.prank(owner);
        vault.setTokenAsGas(none, 20, 10); // 20 whole tokens a day

        _charge(address(usdc), 10e6);
        assertEq(vault.gasBudgetRemaining(), 10e18, "half spent");
        _charge(address(usdc), 10e6);
        assertEq(vault.gasBudgetRemaining(), 0, "spent");

        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(GasBudgetExceeded.selector);
        vault.payRelayerFee(address(usdc), 1e6);
    }

    /// It is a DAILY budget: a new UTC day restores it without anyone acting.
    function test_theBudgetResetsTheNextDay() public {
        address[] memory none = new address[](0);
        vm.prank(owner);
        vault.setTokenAsGas(none, 20, 10);
        // Two charges, because the PER-OP cap is 10 — spending a 20-token day takes two ops.
        _charge(address(usdc), 10e6);
        _charge(address(usdc), 10e6);
        assertEq(vault.gasBudgetRemaining(), 0);

        vm.warp(block.timestamp + 1 days);
        assertEq(vault.gasBudgetRemaining(), 20e18, "a fresh day, a fresh budget");
        _charge(address(usdc), 1e6);
    }

    /// Decimals are normalised to 18 before the ceilings apply, so a 6-dp and an 18-dp coin
    /// consume the same budget for the same value.
    function test_ceilingsAreDecimalNormalised() public {
        guard.setAsset(address(other), ASSET_STABLE_COIN);
        _charge(address(usdc), 3e6); // 3 whole tokens, 6dp
        uint256 afterUsdc = vault.gasBudgetRemaining();
        _charge(address(other), 3e18); // 3 whole tokens, 18dp
        assertEq(afterUsdc - vault.gasBudgetRemaining(), 3e18, "same value, same spend");
    }

    // ── ETH (WETH) as gas ─────────────────────────────────────────────────────

    /// WETH pays at its oracle price, against the same USD budget and per-op cap.
    function test_wethPaysAtOraclePrice() public {
        uint256 before = vault.gasBudgetRemaining();
        _charge(address(weth), 0.001e18); // $2 at $2,000
        assertEq(before - vault.gasBudgetRemaining(), 2e18, "valued in USD");
        assertEq(weth.balanceOf(BITTY_FEE_COLLECTOR), 0.001e18);

        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(FeeExceedsPerOpCap.selector);
        vault.payRelayerFee(address(weth), 0.0051e18); // $10.20 > $10 cap
    }

    /// No trustworthy price, no ETH charge.
    function test_wethChargeFailsClosedOnStalePrice() public {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(PriceStale.selector, address(weth)));
        vault.payRelayerFee(address(weth), 0.001e18);
    }

    /// On an L2, a down sequencer stops ETH charges only; a stable coin reads no feed and still pays.
    function test_aDownSequencerStopsWethButNotStableCoins() public {
        vm.warp(10 hours);
        wethFeed.set(2_000e8, block.timestamp, block.timestamp);
        MockFeed uptime = new MockFeed();
        uptime.set(1, block.timestamp - 2 hours, block.timestamp);
        guard.setSequencerUptimeFeed(address(uptime));

        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(SequencerDown.selector);
        vault.payRelayerFee(address(weth), 0.001e18);

        _charge(address(usdc), 1e6);
    }

    /// WETH and stable coins draw on one USD budget, so mixing them cannot double the day.
    function test_wethAndStableCoinsShareOneDailyBudget() public {
        address[] memory none = new address[](0);
        vm.prank(owner);
        vault.setTokenAsGas(none, 4, 10); // $4 a day

        _charge(address(usdc), 2e6); // $2
        _charge(address(weth), 0.001e18); // $2 at $2,000
        assertEq(vault.gasBudgetRemaining(), 0, "spent across both");

        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(GasBudgetExceeded.selector);
        vault.payRelayerFee(address(weth), 1);
    }

    /// The owner may name WETH; once narrowed to stable coins only, WETH is refused.
    function test_ownerMayNameOrExcludeWeth() public {
        address[] memory onlyWeth = new address[](1);
        onlyWeth[0] = address(weth);
        vm.prank(owner);
        vault.setTokenAsGas(onlyWeth, 10, 1);
        _charge(address(weth), 0.0005e18);

        address[] memory onlyUsdc = new address[](1);
        onlyUsdc[0] = address(usdc);
        vm.prank(owner);
        vault.setTokenAsGas(onlyUsdc, 10, 1);
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(InvalidAsset.selector);
        vault.payRelayerFee(address(weth), 0.0005e18);
    }

    // ── off ───────────────────────────────────────────────────────────────────

    function test_disableTokenAsGasStopsCharging() public {
        vm.prank(owner);
        vault.disableTokenAsGas();
        assertEq(vault.gasBudgetRemaining(), 0, "off reads as no budget");

        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(GasBudgetExceeded.selector);
        vault.payRelayerFee(address(usdc), 1e6);
    }

    /// Off is the tightest the budget gets, so it takes a raise still waiting out the timelock with it.
    /// Were the raise kept, turning token-as-gas back on later would bring it in unannounced.
    function test_disableTokenAsGasCancelsAPendingRaise() public {
        address[] memory none = new address[](0);
        vm.startPrank(owner);
        vault.setTokenAsGas(none, 10, 1); // tightening: at once
        vault.setTokenAsGas(none, 50, 5); // loosening: waits
        vm.stopPrank();
        assertEq(vault.pendingChanges().gasBudgetDaily, 50, "raise queued");
        assertEq(vault.pendingChanges().maxFeePerOp, 5, "raise queued");

        vm.prank(owner);
        vault.disableTokenAsGas();
        assertEq(vault.pendingChanges().gasBudgetDaily, 0, "raise dropped");
        assertEq(vault.pendingChanges().maxFeePerOp, 0, "raise dropped");

        // Long after the raise would have landed, turning it back on with the same numbers is a
        // fresh loosening: it waits again, and the old ceilings hold meanwhile.
        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        vault.setTokenAsGas(none, 50, 5);
        (, uint256 daily, uint256 perOp) = vault.tokenAsGasConfig();
        assertEq(daily, 10, "old budget holds");
        assertEq(perOp, 1, "old cap holds");
        assertEq(vault.pendingChanges().gasBudgetDaily, 50, "raise queued again");
    }

    /// A raise whose time had already come is in force; turning token-as-gas off does not undo it.
    function test_disableTokenAsGasKeepsALandedRaise() public {
        address[] memory none = new address[](0);
        vm.startPrank(owner);
        vault.setTokenAsGas(none, 10, 1);
        vault.setTokenAsGas(none, 50, 5);
        vm.warp(block.timestamp + 30 days);
        vault.disableTokenAsGas();
        vault.setTokenAsGas(none, 50, 5); // the same numbers: nothing to loosen
        vm.stopPrank();
        (, uint256 daily, uint256 perOp) = vault.tokenAsGasConfig();
        assertEq(daily, 50);
        assertEq(perOp, 5);
        assertEq(vault.pendingChanges().gasBudgetDaily, 0, "nothing waiting");
    }

    function test_zeroAmountIsRefused() public {
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(AmountIsZero.selector);
        vault.payRelayerFee(address(usdc), 0);
    }

    function test_onlyOwnerMayConfigure() public {
        address[] memory none = new address[](0);
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert();
        vault.setTokenAsGas(none, 10, 1);
        vm.expectRevert();
        vault.disableTokenAsGas();
        vm.stopPrank();
    }
}
