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
import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    AddressZero,
    ArrayLengthMismatch,
    NotProposalOwner,
    NotPendingApproval,
    ScheduledPaymentNotFound,
    ScheduledPaymentImmutable,
    ScheduledPaymentStartTimestampInPast,
    ScheduledPaymentContentMismatch,
    WhitelistedRecipientNotFound,
    WhitelistedRecipientContentMismatch,
    ImmutableScheduledPaymentLocked,
    ScheduledPaymentTriggerError,
    PayScheduledPaymentAmountTriggerEmpty,
    PayMoreThanScheduledPaymentAmount,
    OnlyImmutablePayableAfterRenounce
} from "../../src/interfaces/IBittyV1Vault.sol";
import {MockERC20 as _Unused} from "solmate/test/utils/mocks/MockERC20.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * Editing what is already queued — the half of the proposal lane that is not "add" or "pay".
 *
 * Scheduled payments and whitelisted recipients share one shape: an operator may propose and may edit
 * or withdraw ONLY their own pending proposal, while the owner may edit or cancel anything and their
 * edit clears the pending flag outright. Approval is bound to a content hash, so an operator cannot
 * amend a proposal between the owner reading it and approving it. An immutable schedule, once locked,
 * is outside all of it.
 */
contract ProposalEditsTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address other = makeAddr("otherOperator");
    address payee = makeAddr("payee");
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
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 1_000e6);

        vm.startPrank(owner);
        vault.updatePayoutOperator(operator, true);
        vault.updatePayoutOperator(other, true);
        vm.stopPrank();
    }

    function _sp(uint256 amount, bool isImmutable) internal view returns (IBittyV1Vault.ScheduledPayment memory) {
        return IBittyV1Vault.ScheduledPayment({
            recipient: payee,
            remainingPaymentCount: 3,
            isImmutable: isImmutable,
            payWithInsufficientBalance: false,
            trigger: address(0),
            assetAddress: address(usdc),
            amount: amount,
            startTimestamp: block.timestamp,
            paymentInterval: 1 days
        });
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _addr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _hashes(bytes32 h) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = h;
    }

    function _sps(IBittyV1Vault.ScheduledPayment memory sp)
        internal
        pure
        returns (IBittyV1Vault.ScheduledPayment[] memory arr)
    {
        arr = new IBittyV1Vault.ScheduledPayment[](1);
        arr[0] = sp;
    }

    function _propose(address by, uint256 amount) internal returns (uint256 id) {
        vm.prank(by);
        return vault.addScheduledPayment(_sp(amount, false));
    }

    // ── scheduled payment edits ───────────────────────────────────────────────

    function test_aScheduleStartingInThePastIsRefused() public {
        vm.warp(1_000_000);
        IBittyV1Vault.ScheduledPayment memory sp = _sp(1e6, false);
        sp.startTimestamp = block.timestamp - 1;
        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentStartTimestampInPast.selector);
        vault.addScheduledPayment(sp);
    }

    function test_editingToAPastStartIsRefused() public {
        uint256 id = _propose(owner, 1e6);
        vm.warp(block.timestamp + 10);
        IBittyV1Vault.ScheduledPayment memory sp = _sp(2e6, false);
        sp.startTimestamp = block.timestamp - 1;
        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentStartTimestampInPast.selector);
        vault.updateScheduledPayments(_ids(id), _sps(sp));
    }

    function test_editingRaggedArraysIsRefused() public {
        uint256[] memory ids = new uint256[](2);
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.updateScheduledPayments(ids, _sps(_sp(1e6, false)));
    }

    function test_editingNothingIsHarmless() public {
        vm.prank(owner);
        vault.updateScheduledPayments(new uint256[](0), new IBittyV1Vault.ScheduledPayment[](0));
    }

    function test_editingAnUnknownScheduleIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentNotFound.selector);
        vault.updateScheduledPayments(_ids(99), _sps(_sp(1e6, false)));
    }

    function test_anImmutableScheduleCannotBeEdited() public {
        vm.prank(owner);
        uint256 id = vault.addScheduledPayment(_sp(1e6, true));
        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentImmutable.selector);
        vault.updateScheduledPayments(_ids(id), _sps(_sp(2e6, false)));
    }

    /// There is no on-chain getter for a schedule, so what is stored is proved by what the owner can
    /// approve: the content hash only matches if the edit landed.
    function test_anOperatorEditsTheirOwnPendingSchedule() public {
        uint256 id = _propose(operator, 1e6);
        IBittyV1Vault.ScheduledPayment memory edited = _sp(2e6, false);
        vm.prank(operator);
        vault.updateScheduledPayments(_ids(id), _sps(edited));

        vm.prank(owner);
        vault.reviewScheduledPayments(_ids(id), _hashes(keccak256(abi.encode(edited))), new uint256[](0));
    }

    function test_anOperatorCannotEditSomebodyElsesPendingSchedule() public {
        uint256 id = _propose(operator, 1e6);
        vm.prank(other);
        vm.expectRevert(NotProposalOwner.selector);
        vault.updateScheduledPayments(_ids(id), _sps(_sp(2e6, false)));
    }

    function test_anOperatorCannotEditAScheduleTheOwnerCreated() public {
        uint256 id = _propose(owner, 1e6);
        vm.prank(operator);
        vm.expectRevert(NotProposalOwner.selector);
        vault.updateScheduledPayments(_ids(id), _sps(_sp(2e6, false)));
    }

    function test_anOwnerEditClearsThePendingFlag() public {
        uint256 id = _propose(operator, 1e6);
        IBittyV1Vault.ScheduledPayment memory edited = _sp(2e6, false);
        vm.prank(owner);
        vault.updateScheduledPayments(_ids(id), _sps(edited));

        vm.prank(owner);
        vm.expectRevert(NotPendingApproval.selector);
        vault.reviewScheduledPayments(_ids(id), _hashes(keccak256(abi.encode(edited))), new uint256[](0));
    }

    function test_anOwnerEditCanMakeAScheduleImmutable() public {
        uint256 id = _propose(owner, 1e6);
        vm.prank(owner);
        vault.updateScheduledPayments(_ids(id), _sps(_sp(1e6, true)));

        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentImmutable.selector);
        vault.updateScheduledPayments(_ids(id), _sps(_sp(9e6, false)));
    }

    function test_reviewingRaggedApprovalArraysIsRefused() public {
        uint256[] memory ids = new uint256[](2);
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.reviewScheduledPayments(ids, _hashes(bytes32(0)), new uint256[](0));
    }

    function test_reviewingNothingIsHarmless() public {
        vm.prank(owner);
        vault.reviewScheduledPayments(new uint256[](0), new bytes32[](0), new uint256[](0));
    }

    function test_approvingAnUnknownScheduleIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentNotFound.selector);
        vault.reviewScheduledPayments(_ids(99), _hashes(bytes32(0)), new uint256[](0));
    }

    function test_approvalIsRefusedIfTheDraftChangedAfterReading() public {
        uint256 id = _propose(operator, 1e6);
        bytes32 read = keccak256(abi.encode(_sp(1e6, false)));

        vm.prank(operator);
        vault.updateScheduledPayments(_ids(id), _sps(_sp(500e6, false)));

        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentContentMismatch.selector);
        vault.reviewScheduledPayments(_ids(id), _hashes(read), new uint256[](0));
    }

    function test_theOwnerCancelsAnOperatorsScheduleThroughReview() public {
        uint256 id = _propose(operator, 1e6);
        vm.prank(owner);
        vault.reviewScheduledPayments(new uint256[](0), new bytes32[](0), _ids(id));

        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentNotFound.selector);
        vault.updateScheduledPayments(_ids(id), _sps(_sp(1e6, false)));
    }

    function test_anOperatorCannotRemoveAnOwnersSchedule() public {
        uint256 id = _propose(owner, 1e6);
        vm.prank(operator);
        vm.expectRevert(NotProposalOwner.selector);
        vault.removeScheduledPayments(_ids(id));
    }

    function test_removingNothingIsHarmless() public {
        vm.prank(owner);
        vault.removeScheduledPayments(new uint256[](0));
    }

    function test_aLockedImmutableScheduleCannotBeRemoved() public {
        vm.prank(owner);
        uint256 id = vault.addScheduledPayment(_sp(1e6, true));
        vm.prank(owner);
        vm.expectRevert(ImmutableScheduledPaymentLocked.selector);
        vault.removeScheduledPayments(_ids(id));
    }

    // ── whitelist edits ───────────────────────────────────────────────────────

    function _wlHash(address recipient, address allowedAsset) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset}))
            );
    }

    function _whitelist(address by) internal returns (uint256 id) {
        vm.prank(by);
        return vault.addWhitelistedRecipient(payee, address(usdc));
    }

    function test_whitelistEditRejectsRaggedArrays() public {
        uint256[] memory ids = new uint256[](2);
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.updateWhitelistedRecipients(ids, _addr(payee), _addr(address(usdc)));
    }

    function test_whitelistEditRejectsTheZeroRecipient() public {
        uint256 id = _whitelist(owner);
        vm.prank(owner);
        vm.expectRevert(AddressZero.selector);
        vault.updateWhitelistedRecipients(_ids(id), _addr(address(0)), _addr(address(usdc)));
    }

    function test_whitelistEditOfAnUnknownIdIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.updateWhitelistedRecipients(_ids(99), _addr(payee), _addr(address(usdc)));
    }

    function test_whitelistEditOfNothingIsHarmless() public {
        vm.prank(owner);
        vault.updateWhitelistedRecipients(new uint256[](0), new address[](0), new address[](0));
    }

    function test_anOperatorEditsTheirOwnPendingWhitelistEntry() public {
        uint256 id = _whitelist(operator);
        address moved = makeAddr("moved");
        vm.prank(operator);
        vault.updateWhitelistedRecipients(_ids(id), _addr(moved), _addr(address(usdc)));
        (address[] memory got,) = vault.getWhitelistedRecipients(_ids(id));
        assertEq(got[0], moved, "the proposer may amend their draft");
    }

    function test_anOperatorCannotEditSomebodyElsesWhitelistEntry() public {
        uint256 id = _whitelist(operator);
        vm.prank(other);
        vm.expectRevert(NotProposalOwner.selector);
        vault.updateWhitelistedRecipients(_ids(id), _addr(payee), _addr(address(usdc)));
    }

    function test_anOwnerWhitelistEditClearsThePendingFlag() public {
        uint256 id = _whitelist(operator);
        vm.prank(owner);
        vault.updateWhitelistedRecipients(_ids(id), _addr(payee), _addr(address(usdc)));

        vm.prank(owner);
        vm.expectRevert(NotPendingApproval.selector);
        vault.reviewWhitelistedRecipients(_ids(id), _hashes(_wlHash(payee, address(usdc))), new uint256[](0));
    }

    function test_whitelistReviewRejectsRaggedApprovalArrays() public {
        uint256[] memory ids = new uint256[](2);
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.reviewWhitelistedRecipients(ids, _hashes(bytes32(0)), new uint256[](0));
    }

    function test_whitelistApprovalOfAnUnknownIdIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.reviewWhitelistedRecipients(_ids(99), _hashes(bytes32(0)), new uint256[](0));
    }

    function test_whitelistApprovalIsRefusedIfTheDraftChanged() public {
        uint256 id = _whitelist(operator);
        bytes32 read = _wlHash(payee, address(usdc));

        vm.prank(operator);
        vault.updateWhitelistedRecipients(_ids(id), _addr(makeAddr("elsewhere")), _addr(address(usdc)));

        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientContentMismatch.selector);
        vault.reviewWhitelistedRecipients(_ids(id), _hashes(read), new uint256[](0));
    }

    function test_whitelistReviewOfNothingIsHarmless() public {
        vm.prank(owner);
        vault.reviewWhitelistedRecipients(new uint256[](0), new bytes32[](0), new uint256[](0));
    }

    function test_removingAnUnknownWhitelistEntryIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.removeWhitelistedRecipients(_ids(99));
    }

    function test_removingNoWhitelistEntriesIsHarmless() public {
        vm.prank(owner);
        vault.removeWhitelistedRecipients(new uint256[](0));
    }

    function test_anOperatorCannotRemoveAnOwnersWhitelistEntry() public {
        uint256 id = _whitelist(owner);
        vm.prank(operator);
        vm.expectRevert(NotProposalOwner.selector);
        vault.removeWhitelistedRecipients(_ids(id));
    }

    function test_theOwnerCancelsAnOperatorsWhitelistEntryThroughReview() public {
        uint256 id = _whitelist(operator);
        vm.prank(owner);
        vault.reviewWhitelistedRecipients(new uint256[](0), new bytes32[](0), _ids(id));
        (address[] memory got,) = vault.getWhitelistedRecipients(_ids(id));
        assertEq(got[0], address(0), "gone");
    }

    // ── approving an immutable proposal starts its lock ───────────────────────

    /**
     * An operator may propose an IMMUTABLE schedule, but proposing one does not seal it. The lock only
     * starts counting when the owner approves — otherwise an operator could create something the owner
     * can never edit or remove simply by naming it immutable.
     */
    function test_approvingAnImmutableProposalStartsTheLock() public {
        IBittyV1Vault.ScheduledPayment memory sp = _sp(1e6, true);
        vm.prank(operator);
        uint256 id = vault.addScheduledPayment(sp);

        vm.prank(owner);
        vault.removeScheduledPayments(_ids(id));

        vm.prank(operator);
        id = vault.addScheduledPayment(sp);
        vm.prank(owner);
        vault.reviewScheduledPayments(_ids(id), _hashes(keccak256(abi.encode(sp))), new uint256[](0));

        vm.prank(owner);
        vm.expectRevert(ImmutableScheduledPaymentLocked.selector);
        vault.removeScheduledPayments(_ids(id));
    }

    // ── payScheduledAmount is trigger-only ────────────────────────────────────

    function _triggered(uint256 amount, address trg) internal returns (uint256 id) {
        IBittyV1Vault.ScheduledPayment memory sp = _sp(amount, false);
        sp.trigger = trg;
        vm.prank(owner);
        id = vault.addScheduledPayment(sp);
    }

    function test_partialPaymentNeedsANamedTrigger() public {
        uint256 id = _propose(owner, 10e6);
        vm.prank(owner);
        vm.expectRevert(PayScheduledPaymentAmountTriggerEmpty.selector);
        vault.payScheduledAmount(id, 1e6);
    }

    function test_onlyTheNamedTriggerMayDrawADownPayment() public {
        address trg = makeAddr("trigger");
        uint256 id = _triggered(10e6, trg);

        vm.prank(owner);
        vm.expectRevert(ScheduledPaymentTriggerError.selector);
        vault.payScheduledAmount(id, 1e6);

        vm.prank(trg);
        vault.payScheduledAmount(id, 1e6);
        assertEq(usdc.balanceOf(payee), 1e6, "the trigger drew part of it");
    }

    function test_aDownPaymentCannotExceedTheSchedule() public {
        address trg = makeAddr("trigger");
        uint256 id = _triggered(10e6, trg);
        vm.prank(trg);
        vm.expectRevert(PayMoreThanScheduledPaymentAmount.selector);
        vault.payScheduledAmount(id, 11e6);
    }

    /// Opted into partial payment and the vault is empty: the run is SKIPPED, not reverted, so a
    /// keeper sweeping many schedules is not blocked by one that has nothing to pay from.
    function test_anEmptyVaultSkipsTheDownPaymentInsteadOfReverting() public {
        address trg = makeAddr("trigger");
        IBittyV1Vault.ScheduledPayment memory sp = _sp(10e6, false);
        sp.trigger = trg;
        sp.payWithInsufficientBalance = true;
        vm.prank(owner);
        uint256 id = vault.addScheduledPayment(sp);

        vm.prank(owner);
        vault.send(makeAddr("drain"), address(usdc), 1_000e6, new address[](0), new uint256[](0));
        assertEq(usdc.balanceOf(address(vault)), 0, "nothing left to pay with");

        vm.prank(trg);
        vault.payScheduledAmount(id, 1e6);
        assertEq(usdc.balanceOf(payee), 0, "skipped quietly");
    }

    // ── after renounce, only a locked immutable schedule still pays ───────────

    function test_afterRenounceAnOrdinaryScheduleIsDead() public {
        uint256 ordinary = _propose(owner, 10e6);

        vm.prank(owner);
        uint256 rescue = vault.addScheduledPayment(_sp(5e6, true));
        vm.prank(owner);
        vault.renounceVaultOwnership(rescue);

        vm.expectRevert(OnlyImmutablePayableAfterRenounce.selector);
        vault.payScheduled(ordinary, new address[](0));
    }

    function test_afterRenounceTheLockedImmutableScheduleStillPays() public {
        vm.prank(owner);
        uint256 rescue = vault.addScheduledPayment(_sp(5e6, true));
        vm.prank(owner);
        vault.renounceVaultOwnership(rescue);

        vault.payScheduled(rescue, new address[](0));
        assertEq(usdc.balanceOf(payee), 5e6, "the rescue route survives the owner");
    }
}
