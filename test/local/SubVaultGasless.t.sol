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
    InvalidAsset,
    FeeExceedsPerOpCap,
    GasBudgetTooHigh,
    GasBudgetExceeded,
    AmountIsZero,
    AddressZero,
    InvalidRelayedCalldata
} from "../../src/interfaces/IBittyV1Vault.sol";
import {NotSubOwner} from "../../src/interfaces/IBittyV1SubVault.sol";
import {SYSTEM_DAILY_MAX_GAS_BUDGET, SYSTEM_MAX_FEE_PER_OP} from "../../src/logic/Constants.sol";
import {BITTY_GUARD, BITTY_FORWARDER, BITTY_FEE_COLLECTOR, STABLE_COIN_CATEGORY} from "../../src/logic/Constants.sol";

/**
 * Per-sub gasless: the OWNER flips the switch, the SUB OWNER tunes the limits, and the sub pays its own
 * relayer fee out of its own balance — to the fixed fee collector, bounded, never to an arbitrary payee.
 */
contract SubVaultGaslessTest is Test {
    BittyV1VaultDeFiFacet facet;
    BittyV1Vault vault;
    BittyV1SubVault subImpl;
    BittyV1SubVault sub;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address subOwner = makeAddr("subOwner");
    address weth = makeAddr("weth");
    uint256 subId;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        facet = new BittyV1VaultDeFiFacet();
        subImpl = new BittyV1SubVault(address(facet));
        MockGuard(BITTY_GUARD).setImpl(address(subImpl), true);

        BittyV1Vault vaultImpl = new BittyV1Vault(address(facet), address(subImpl));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(vaultImpl), abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0))
                ))
        );

        usdc = new MockERC20("USD Coin", "USDC", 6);
        MockGuard(BITTY_GUARD).setAsset(address(usdc), STABLE_COIN_CATEGORY);

        address account;
        vm.prank(owner);
        (subId, account) = vault.createSubVault(subOwner, false, uint64(block.timestamp) + 365 days);
        sub = BittyV1SubVault(payable(account));
        usdc.mint(address(sub), 1_000e6);
    }

    function test_gaslessOff_relayerFeeReverts() public {
        // Default off: even the forwarder can't charge the sub.
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(BittyV1SubVault.SubGaslessDisabled.selector);
        sub.payRelayerFee(address(usdc), 5e6);
    }

    function test_ownerSwitchOn_thenForwarderCharges() public {
        vm.prank(owner);
        vault.setSubVaultGasless(subId, true);

        // The sub owner tunes its budget within the system ceiling.
        vm.prank(subOwner);
        sub.setGasless(50, 8);

        // The forwarder reclaims a fee from the sub's own balance, to the fee collector.
        vm.prank(BITTY_FORWARDER);
        sub.payRelayerFee(address(usdc), 5e6);

        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 5e6, "fee to collector");
        assertEq(usdc.balanceOf(address(sub)), 995e6, "sub paid its own fee");
    }

    function test_onlyForwarderCanCharge() public {
        vm.prank(owner);
        vault.setSubVaultGasless(subId, true);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotTrustedForwarder.selector);
        sub.payRelayerFee(address(usdc), 5e6);
    }

    function test_nonStablecoinRejected() public {
        vm.prank(owner);
        vault.setSubVaultGasless(subId, true);
        MockERC20 notStable = new MockERC20("WBTC", "WBTC", 8); // no guard category
        notStable.mint(address(sub), 1e8);
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(InvalidAsset.selector);
        sub.payRelayerFee(address(notStable), 1e6);
    }

    function test_gasBudgetRemaining_tracksSwitchAndSpend() public {
        assertEq(sub.gasBudgetRemaining(), 0, "off => 0 (forwarder pre-check fails)");
        vm.prank(owner);
        vault.setSubVaultGasless(subId, true);
        assertEq(sub.gasBudgetRemaining(), 100e18, "full daily allowance when on");
        vm.prank(BITTY_FORWARDER);
        sub.payRelayerFee(address(usdc), 5e6); // 5 USDC → 5e18 of value
        assertEq(sub.gasBudgetRemaining(), 100e18 - 5e18, "reduced by the fee's normalized value");
    }

    function test_feeOverPerOpCapRejected() public {
        vm.prank(owner);
        vault.setSubVaultGasless(subId, true);
        // System per-op cap is 10 whole tokens; 20 USDC exceeds it.
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(FeeExceedsPerOpCap.selector);
        sub.payRelayerFee(address(usdc), 20e6);
    }

    // ── sub-owner tuning bounds ───────────────────────────────────────────────

    function test_aSubOwnerCannotRaiseTheDailyLimitAboveTheSystemCeiling() public {
        vm.prank(subOwner);
        vm.expectRevert(GasBudgetTooHigh.selector);
        sub.setGasless(SYSTEM_DAILY_MAX_GAS_BUDGET + 1, 5);
    }

    function test_aSubOwnerCannotRaiseThePerOpCapAboveTheSystemCeiling() public {
        vm.prank(subOwner);
        vm.expectRevert(FeeExceedsPerOpCap.selector);
        sub.setGasless(50, SYSTEM_MAX_FEE_PER_OP + 1);
    }

    function test_onlyTheSubOwnerTunesTheBudget() public {
        vm.prank(owner);
        vm.expectRevert(NotSubOwner.selector);
        sub.setGasless(50, 5);
    }

    function test_zeroMeansTheSystemDefaultNotZeroBudget() public {
        vm.prank(owner);
        vault.setSubVaultGasless(subId, true);
        (, uint256 dailyLimit, uint256 maxFeePerOp) = sub.gaslessConfig();
        assertEq(dailyLimit, SYSTEM_DAILY_MAX_GAS_BUDGET, "unset means the system ceiling");
        assertEq(maxFeePerOp, SYSTEM_MAX_FEE_PER_OP, "same for the per-op cap");
    }

    // ── charging bounds ───────────────────────────────────────────────────────

    function test_aZeroFeeIsRefused() public {
        vm.prank(owner);
        vault.setSubVaultGasless(subId, true);
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(AmountIsZero.selector);
        sub.payRelayerFee(address(usdc), 0);
    }

    function test_theDailyBudgetIsSpentDownAcrossSeveralCharges() public {
        vm.prank(owner);
        vault.setSubVaultGasless(subId, true);
        vm.prank(subOwner);
        sub.setGasless(12, 10);

        vm.startPrank(BITTY_FORWARDER);
        sub.payRelayerFee(address(usdc), 7e6);
        assertEq(sub.gasBudgetRemaining(), 5e18, "7 of 12 spent");
        vm.expectRevert(GasBudgetExceeded.selector);
        sub.payRelayerFee(address(usdc), 6e6);
        vm.stopPrank();
    }

    function test_theBudgetRefillsTheNextDay() public {
        vm.prank(owner);
        vault.setSubVaultGasless(subId, true);
        vm.prank(subOwner);
        sub.setGasless(12, 10);

        vm.prank(BITTY_FORWARDER);
        sub.payRelayerFee(address(usdc), 7e6);
        assertEq(sub.gasBudgetRemaining(), 5e18, "spent today");

        vm.warp(block.timestamp + 1 days);
        assertEq(sub.gasBudgetRemaining(), 12e18, "a new day starts from the full limit");
        vm.prank(BITTY_FORWARDER);
        sub.payRelayerFee(address(usdc), 7e6);
    }

    function test_anExhaustedBudgetReadsZeroNotNegative() public {
        vm.prank(owner);
        vault.setSubVaultGasless(subId, true);
        vm.prank(subOwner);
        sub.setGasless(10, 10);

        vm.prank(BITTY_FORWARDER);
        sub.payRelayerFee(address(usdc), 10e6);
        assertEq(sub.gasBudgetRemaining(), 0, "fully spent");
    }

    // ── parent-gated admin ────────────────────────────────────────────────────

    function test_theParentCannotHandTheSubToNobody() public {
        vm.prank(address(vault));
        vm.expectRevert(AddressZero.selector);
        sub.setSubOwner(address(0), 0);
    }

    function test_theImplementationCannotBeInitializedDirectly() public {
        vm.expectRevert();
        subImpl.initialize(address(vault), subOwner, false, 0);
    }

    function test_shortRelayedCalldataIsRefusedRatherThanDelegated() public {
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(InvalidRelayedCalldata.selector);
        (bool ok,) = address(sub).call(hex"11223344");
        ok;
    }
}
