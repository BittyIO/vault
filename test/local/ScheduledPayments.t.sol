// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    AddressZero,
    AmountIsZero,
    InsufficientBalance,
    NotPayoutOperator,
    PaymentNotApproved,
    NotPendingApproval,
    ProtectionPeriodNotEnded,
    ScheduledPaymentNotFound,
    ScheduledPaymentPaymentCountZero,
    ScheduledPaymentTriggerError,
    ScheduledPaymentNotStartYet,
    ScheduledPaymentInInterval,
    ScheduledPaymentContentMismatch,
    AssetAddressNotContract,
    PayMoreThanScheduledPaymentAmount,
    PayScheduledPaymentAmountTriggerEmpty
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * Scheduled payments: the vault paying out on its own schedule, without the owner present.
 *
 * The accrual rules are the whole contract — start time, interval, remaining count, approval, the
 * protection window — because they are what decides when money may leave with nobody watching.
 */
contract ScheduledPaymentsTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address payee = makeAddr("payee");
    address trigger = makeAddr("trigger");
    address weth = makeAddr("weth");

    uint256 constant UNCHANGED = type(uint256).max;
    uint256 constant UNLIMITED = type(uint256).max;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 1_000e6);

        vm.prank(owner);
        vault.updatePayoutOperator(operator, true);
    }

    function _sp(uint256 count, address trg, uint256 amount, uint256 start, uint256 interval)
        internal
        view
        returns (IBittyV1Vault.ScheduledPayment memory)
    {
        return IBittyV1Vault.ScheduledPayment({
            recipient: payee,
            remainingPaymentCount: count,
            isImmutable: false,
            payWithInsufficientBalance: false,
            trigger: trg,
            assetAddress: address(usdc),
            amount: amount,
            startTimestamp: start,
            paymentInterval: interval
        });
    }

    function _add(IBittyV1Vault.ScheduledPayment memory sp) internal returns (uint256 id) {
        vm.prank(owner);
        return vault.addScheduledPayment(sp);
    }

    function _pay(uint256 id, address as_) internal {
        vm.prank(as_);
        vault.payScheduled(id, new address[](0));
    }

    function _ids(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    // ── the happy path ────────────────────────────────────────────────────────

    function test_paysOnScheduleAndDecrementsTheCount() public {
        uint256 id = _add(_sp(2, address(0), 10e6, block.timestamp, 0));
        _pay(id, owner);
        assertEq(usdc.balanceOf(payee), 10e6);
        _pay(id, owner);
        assertEq(usdc.balanceOf(payee), 20e6);

        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        _pay(id, owner);
    }

    /// An unlimited schedule never decrements, so it never runs out.
    function test_unlimitedScheduleNeverRunsOut() public {
        uint256 id = _add(_sp(UNLIMITED, address(0), 1e6, block.timestamp, 0));
        for (uint256 i; i < 5; i++) {
            _pay(id, owner);
        }
        assertEq(usdc.balanceOf(payee), 5e6);
    }

    // ── the accrual rules ─────────────────────────────────────────────────────

    function test_notBeforeItsStartTime() public {
        uint256 id = _add(_sp(1, address(0), 10e6, block.timestamp + 1 days, 0));
        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentNotStartYet.selector);
        vault.payScheduled(id, new address[](0));

        vm.warp(block.timestamp + 1 days);
        _pay(id, owner);
        assertEq(usdc.balanceOf(payee), 10e6);
    }

    /// The interval is what stops a schedule being drained in one block.
    function test_intervalRateLimitsTheSchedule() public {
        uint256 id = _add(_sp(5, address(0), 10e6, block.timestamp, 7 days));
        _pay(id, owner);

        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentInInterval.selector);
        vault.payScheduled(id, new address[](0));

        vm.warp(block.timestamp + 7 days);
        _pay(id, owner);
        assertEq(usdc.balanceOf(payee), 20e6, "one interval later, one more payment");
    }

    /**
     * Paying is otherwise PERMISSIONLESS — that is the point of a schedule, it must run without the
     * owner. A named trigger narrows it to one caller.
     */
    function test_withoutATriggerAnyoneMayPay() public {
        uint256 id = _add(_sp(1, address(0), 10e6, block.timestamp, 0));
        _pay(id, makeAddr("anyone"));
        assertEq(usdc.balanceOf(payee), 10e6);
    }

    function test_aNamedTriggerIsTheOnlyCaller() public {
        uint256 id = _add(_sp(1, trigger, 10e6, block.timestamp, 0));
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(ScheduledPaymentTriggerError.selector);
        vault.payScheduled(id, new address[](0));

        _pay(id, trigger);
        assertEq(usdc.balanceOf(payee), 10e6);
    }

    // ── balance handling ──────────────────────────────────────────────────────

    /// Short by default is a revert: a partial payment nobody asked for is worse than none.
    function test_insufficientBalanceRevertsByDefault() public {
        uint256 id = _add(_sp(1, address(0), 5_000e6, block.timestamp, 0));
        vm.prank(owner);
        vm.expectRevert(InsufficientBalance.selector);
        vault.payScheduled(id, new address[](0));
    }

    /// Unless the schedule opted in, in which case it pays what is there.
    function test_partialPaymentWhenOptedIn() public {
        IBittyV1Vault.ScheduledPayment memory sp = _sp(1, address(0), 5_000e6, block.timestamp, 0);
        sp.payWithInsufficientBalance = true;
        uint256 id = _add(sp);
        _pay(id, owner);
        assertEq(usdc.balanceOf(payee), 1_000e6, "paid what the vault had");
    }

    /// An opted-in schedule with NOTHING to pay is skipped silently rather than reverting — a
    /// permissionless caller must not be able to burn gas proving the vault is empty.
    function test_emptyVaultIsSkippedNotReverted() public {
        IBittyV1Vault.ScheduledPayment memory sp = _sp(2, address(0), 10e6, block.timestamp, 0);
        sp.payWithInsufficientBalance = true;
        uint256 id = _add(sp);

        vm.prank(address(vault));
        usdc.transfer(makeAddr("elsewhere"), 1_000e6); // drain it

        _pay(id, owner); // no revert
        assertEq(usdc.balanceOf(payee), 0, "nothing paid");

        // The count was not consumed either: refunded, both payments are still available.
        usdc.mint(address(vault), 100e6);
        _pay(id, owner);
        _pay(id, owner);
        assertEq(usdc.balanceOf(payee), 20e6, "both payments survived the skip");
    }

    // ── proposals and approval ────────────────────────────────────────────────

    function test_operatorProposalIsUnpayableUntilApproved() public {
        IBittyV1Vault.ScheduledPayment memory proposed = _sp(1, address(0), 10e6, block.timestamp, 0);
        vm.prank(operator);
        uint256 id = vault.addScheduledPayment(proposed);

        vm.prank(owner);
        vm.expectRevert(PaymentNotApproved.selector);
        vault.payScheduled(id, new address[](0));

        // There is no on-chain getter for a scheduled payment, so the hash is taken over what was
        // submitted — which is exactly what the contract stored (`scheduledPayments[id] = sp`).
        vm.prank(owner);
        vault.reviewScheduledPayments(_ids(id), _hashes(keccak256(abi.encode(proposed))), new uint256[](0));

        _pay(id, owner);
        assertEq(usdc.balanceOf(payee), 10e6);
    }

    /// Approval binds to the exact content reviewed, so a proposer cannot swap the payee afterwards.
    function test_approvalIsBoundToTheContentReviewed() public {
        IBittyV1Vault.ScheduledPayment memory shown = _sp(1, address(0), 10e6, block.timestamp, 0);
        vm.prank(operator);
        uint256 id = vault.addScheduledPayment(shown);

        // A fresh struct, NOT `= shown`: memory structs alias in Solidity, so mutating a copy would
        // silently mutate the original and the hash below would match the tampered entry.
        IBittyV1Vault.ScheduledPayment memory swapped = _sp(1, address(0), 10e6, shown.startTimestamp, 0);
        swapped.recipient = makeAddr("attacker");
        IBittyV1Vault.ScheduledPayment[] memory arr = new IBittyV1Vault.ScheduledPayment[](1);
        arr[0] = swapped;
        vm.prank(operator);
        vault.updateScheduledPayments(_ids(id), arr);

        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentContentMismatch.selector);
        vault.reviewScheduledPayments(_ids(id), _hashes(keccak256(abi.encode(shown))), new uint256[](0));
    }

    function test_ownerCancelsAProposal() public {
        vm.prank(operator);
        uint256 id = vault.addScheduledPayment(_sp(1, address(0), 10e6, block.timestamp, 0));
        vm.prank(owner);
        vault.reviewScheduledPayments(new uint256[](0), new bytes32[](0), _ids(id));

        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentNotFound.selector);
        vault.payScheduled(id, new address[](0));
    }

    // ── the protection window ─────────────────────────────────────────────────

    function test_aNewScheduleWaitsOutTheProtectionWindow() public {
        vm.prank(owner);
        vault.updatePaymentRisk(IBittyV1Owner.PaymentRisk(3 days, UNCHANGED, UNCHANGED, UNCHANGED));
        uint256 id = _add(_sp(1, address(0), 10e6, block.timestamp, 0));

        vm.prank(owner);
        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        vault.payScheduled(id, new address[](0));

        vm.warp(block.timestamp + 3 days);
        _pay(id, owner);
        assertEq(usdc.balanceOf(payee), 10e6);
    }

    // ── payScheduledAmount ────────────────────────────────────────────────────

    /// The variable-amount path is trigger-only: without one, anybody could choose the amount.
    function test_payScheduledAmountRequiresATrigger() public {
        uint256 id = _add(_sp(1, address(0), 10e6, block.timestamp, 0));
        vm.prank(owner);
        vm.expectRevert(PayScheduledPaymentAmountTriggerEmpty.selector);
        vault.payScheduledAmount(id, 1e6);
    }

    function test_payScheduledAmountIsCappedByTheSchedule() public {
        uint256 id = _add(_sp(1, trigger, 10e6, block.timestamp, 0));
        vm.prank(trigger);
        vm.expectRevert(PayMoreThanScheduledPaymentAmount.selector);
        vault.payScheduledAmount(id, 11e6);

        vm.prank(trigger);
        vault.payScheduledAmount(id, 4e6);
        assertEq(usdc.balanceOf(payee), 4e6, "less than the schedule is fine");
    }

    // ── validation ────────────────────────────────────────────────────────────

    function test_rejectsBadSchedules() public {
        vm.startPrank(owner);
        IBittyV1Vault.ScheduledPayment memory sp = _sp(1, address(0), 10e6, block.timestamp, 0);

        sp.recipient = address(0);
        vm.expectRevert(AddressZero.selector);
        vault.addScheduledPayment(sp);
        sp.recipient = payee;

        sp.amount = 0;
        vm.expectRevert(AmountIsZero.selector);
        vault.addScheduledPayment(sp);
        sp.amount = 10e6;

        sp.remainingPaymentCount = 0;
        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        vault.addScheduledPayment(sp);
        sp.remainingPaymentCount = 1;

        sp.assetAddress = makeAddr("notAContract");
        vm.expectRevert(AssetAddressNotContract.selector);
        vault.addScheduledPayment(sp);
        vm.stopPrank();
    }

    function test_strangersCannotSchedule() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotPayoutOperator.selector);
        vault.addScheduledPayment(_sp(1, address(0), 10e6, block.timestamp, 0));
    }

    function test_removedScheduleCannotBePaid() public {
        uint256 id = _add(_sp(1, address(0), 10e6, block.timestamp, 0));
        vm.prank(owner);
        vault.removeScheduledPayments(_ids(id));
        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentNotFound.selector);
        vault.payScheduled(id, new address[](0));
    }

    function _hashes(bytes32 h) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = h;
    }
}
