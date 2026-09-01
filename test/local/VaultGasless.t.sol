// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
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
    STABLE_COIN_CATEGORY,
    SYSTEM_DAILY_MAX_GAS_BUDGET,
    SYSTEM_MAX_FEE_PER_OP
} from "../../src/logic/Constants.sol";

/**
 * The main vault paying its own relayed gas, in stable coin.
 *
 * Two ceilings bound what a relayer can take — a per-charge cap and a per-day budget — and the vault
 * enforces both itself, so a compromised relayer can overcharge by a bounded amount and never more.
 */
contract VaultGaslessTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 other;

    address owner = makeAddr("owner");
    address weth = makeAddr("weth");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        other = new MockERC20("Other", "OTH", 18);
        guard.setAsset(address(usdc), STABLE_COIN_CATEGORY);
        usdc.mint(address(vault), 1_000_000e6);
        other.mint(address(vault), 1_000e18);
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
     * A vault that never called setGasless is relayable, at the system defaults, in any stable coin
     * the guard registers. An empty list means "anything permitted", not "nothing" — read the other
     * way, gasless would be off for every fresh vault while gasBudgetRemaining reported a full day.
     */
    function test_freshVaultIsRelayableAtSystemDefaults() public {
        (address[] memory assets, uint256 daily, uint256 perOp) = vault.gaslessConfig();
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
        guard.setAsset(address(other), STABLE_COIN_CATEGORY);
        address[] memory only = new address[](1);
        only[0] = address(usdc);

        vm.prank(owner);
        vault.setGasless(only, 50, 5);

        (address[] memory assets, uint256 daily, uint256 perOp) = vault.gaslessConfig();
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
        vault.setGasless(none, SYSTEM_DAILY_MAX_GAS_BUDGET + 1, 1);
        vm.expectRevert(FeeExceedsPerOpCap.selector);
        vault.setGasless(none, 1, SYSTEM_MAX_FEE_PER_OP + 1);
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
        vault.setGasless(none, 20, 10); // 20 whole tokens a day

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
        vault.setGasless(none, 20, 10);
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
        guard.setAsset(address(other), STABLE_COIN_CATEGORY);
        _charge(address(usdc), 3e6); // 3 whole tokens, 6dp
        uint256 afterUsdc = vault.gasBudgetRemaining();
        _charge(address(other), 3e18); // 3 whole tokens, 18dp
        assertEq(afterUsdc - vault.gasBudgetRemaining(), 3e18, "same value, same spend");
    }

    // ── off ───────────────────────────────────────────────────────────────────

    function test_disableGaslessStopsCharging() public {
        vm.prank(owner);
        vault.disableGasless();
        assertEq(vault.gasBudgetRemaining(), 0, "off reads as no budget");

        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(GasBudgetExceeded.selector);
        vault.payRelayerFee(address(usdc), 1e6);
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
        vault.setGasless(none, 10, 1);
        vm.expectRevert();
        vault.disableGasless();
        vm.stopPrank();
    }
}
