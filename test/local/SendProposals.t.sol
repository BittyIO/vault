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
import {
    AddressZero,
    AmountIsZero,
    PaymentNotStableCoin,
    PaymentExceedsRiskCap,
    PaymentExceedsPeriodLimit,
    EmptyArray,
    ArrayLengthMismatch,
    NotProposalOwner,
    PendingSendNotFound,
    PayoutOperatorNotFound,
    PayoutOperatorAlreadyRegistered,
    TransferFailed
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

contract WETHStub {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth back");
    }

    receive() external payable {}
}

/// Refuses plain ETH, so the native payout path has a failing transfer to report.
contract RejectsEth {
    receive() external payable {
        revert("no thanks");
    }
}

/**
 * The proposal lane: what a payout operator may put forward, and what only the owner may release.
 *
 * An operator never moves money. `batchSend`/`send` from an operator become PROPOSALS, validated
 * immediately so a bad batch is refused at proposal time rather than sitting in the queue, but paid out
 * only when the owner approves. The asymmetry in cancellation is the point — the owner can cancel
 * anything, an operator only their own.
 */
contract SendProposalsTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    WETHStub weth;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address other = makeAddr("otherOperator");
    address payee = makeAddr("payee");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        weth = new WETHStub();
        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, address(weth), false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 100_000e6);

        vm.startPrank(owner);
        vault.updatePayoutOperator(operator, true);
        vault.updatePayoutOperator(other, true);
        vm.stopPrank();
    }

    function _addr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _amt(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _batch(address caller, address[] memory r, address[] memory a, uint256[] memory m) internal {
        vm.prank(caller);
        vault.batchSend(r, a, m, new address[][](0), new uint256[][](0));
    }

    // ── batch argument handling ───────────────────────────────────────────────

    function test_anEmptyBatchIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(EmptyArray.selector);
        vault.batchSend(new address[](0), new address[](0), new uint256[](0), new address[][](0), new uint256[][](0));
    }

    function test_aRaggedBatchIsRefused() public {
        address[] memory r = new address[](2);
        r[0] = payee;
        r[1] = payee;
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.batchSend(r, _addr(address(usdc)), _amt(1e6), new address[][](0), new uint256[][](0));
    }

    function test_aRaggedBatchIsRefusedOnAmountsToo() public {
        uint256[] memory m = new uint256[](2);
        m[0] = 1e6;
        m[1] = 1e6;
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.batchSend(_addr(payee), _addr(address(usdc)), m, new address[][](0), new uint256[][](0));
    }

    function test_ownerBatchPaysEveryLeg() public {
        address second = makeAddr("second");
        address[] memory r = new address[](2);
        address[] memory a = new address[](2);
        uint256[] memory m = new uint256[](2);
        r[0] = payee;
        r[1] = second;
        a[0] = address(usdc);
        a[1] = address(usdc);
        m[0] = 1e6;
        m[1] = 2e6;
        _batch(owner, r, a, m);
        assertEq(usdc.balanceOf(payee), 1e6);
        assertEq(usdc.balanceOf(second), 2e6);
    }

    // ── proposals ─────────────────────────────────────────────────────────────

    function test_anOperatorBatchMovesNoMoneyUntilApproved() public {
        _batch(operator, _addr(payee), _addr(address(usdc)), _amt(5e6));
        assertEq(usdc.balanceOf(payee), 0, "a proposal is not a payment");

        vm.prank(owner);
        vault.approveSend(0);
        assertEq(usdc.balanceOf(payee), 5e6, "the owner's approval is what pays");
    }

    function test_aBadProposalIsRefusedAtProposalTimeNotAtApproval() public {
        vm.prank(operator);
        vm.expectRevert(AddressZero.selector);
        vault.batchSend(_addr(address(0)), _addr(address(usdc)), _amt(1e6), new address[][](0), new uint256[][](0));
    }

    function test_aZeroAmountProposalIsRefused() public {
        vm.prank(operator);
        vm.expectRevert(AmountIsZero.selector);
        vault.send(payee, address(usdc), 0, new address[](0), new uint256[](0));
    }

    function test_reviewApprovesAndCancelsInOneCall() public {
        _batch(operator, _addr(payee), _addr(address(usdc)), _amt(1e6));
        _batch(operator, _addr(payee), _addr(address(usdc)), _amt(2e6));

        vm.prank(owner);
        vault.reviewSends(_ids(0), _ids(1));

        assertEq(usdc.balanceOf(payee), 1e6, "only the approved one paid");
        vm.prank(owner);
        vm.expectRevert(PendingSendNotFound.selector);
        vault.approveSend(1);
    }

    function test_reviewWithNothingToDoIsHarmless() public {
        vm.prank(owner);
        vault.reviewSends(new uint256[](0), new uint256[](0));
    }

    function test_cancellingNothingIsHarmless() public {
        vm.prank(owner);
        vault.cancelSends(new uint256[](0));
    }

    function test_approvingAnUnknownIdIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(PendingSendNotFound.selector);
        vault.approveSend(99);
    }

    function test_cancellingAnUnknownIdIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(PendingSendNotFound.selector);
        vault.cancelSend(99);
    }

    function test_anOperatorCancelsTheirOwnProposal() public {
        _batch(operator, _addr(payee), _addr(address(usdc)), _amt(1e6));
        vm.prank(operator);
        vault.cancelSend(0);

        vm.prank(owner);
        vm.expectRevert(PendingSendNotFound.selector);
        vault.approveSend(0);
    }

    function test_anOperatorCannotCancelSomebodyElsesProposal() public {
        _batch(operator, _addr(payee), _addr(address(usdc)), _amt(1e6));
        vm.prank(other);
        vm.expectRevert(NotProposalOwner.selector);
        vault.cancelSend(0);
    }

    function test_theOwnerCanCancelAnybodysProposal() public {
        _batch(operator, _addr(payee), _addr(address(usdc)), _amt(1e6));
        vm.prank(owner);
        vault.cancelSends(_ids(0));

        vm.prank(owner);
        vm.expectRevert(PendingSendNotFound.selector);
        vault.approveSend(0);
    }

    function test_proposalIdsDoNotRepeat() public {
        _batch(operator, _addr(payee), _addr(address(usdc)), _amt(1e6));
        vm.prank(operator);
        vault.cancelSend(0);
        _batch(operator, _addr(payee), _addr(address(usdc)), _amt(1e6));

        vm.prank(owner);
        vm.expectRevert(PendingSendNotFound.selector);
        vault.approveSend(0);
        vm.prank(owner);
        vault.approveSend(1);
    }

    /// A direct send carries no balance pre-check of its own — the token's accounting is the backstop.
    /// The InsufficientBalance guard belongs to the scheduled-payment path, which has to decide between
    /// paying short and not paying at all.
    function test_aSendLargerThanTheBalanceIsRefused() public {
        vm.prank(owner);
        vm.expectRevert();
        vault.send(payee, address(usdc), 200_000e6, new address[](0), new uint256[](0));
        assertEq(usdc.balanceOf(payee), 0, "and nothing moved");
    }

    // ── payout operator bookkeeping ───────────────────────────────────────────

    function test_addingTheSameOperatorTwiceIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(PayoutOperatorAlreadyRegistered.selector);
        vault.updatePayoutOperator(operator, true);
    }

    function test_removingSomebodyWhoIsNotAnOperatorIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(PayoutOperatorNotFound.selector);
        vault.updatePayoutOperator(makeAddr("nobody"), false);
    }

    function test_addingTheZeroOperatorIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(AddressZero.selector);
        vault.updatePayoutOperator(address(0), true);
    }

    function test_aRemovedOperatorCannotPropose() public {
        vm.prank(owner);
        vault.updatePayoutOperator(operator, false);
        vm.prank(operator);
        vm.expectRevert();
        vault.send(payee, address(usdc), 1e6, new address[](0), new uint256[](0));
    }

    // ── native ETH payout ─────────────────────────────────────────────────────

    function test_theZeroAssetPaysRealEthByUnwrappingWeth() public {
        weth.mint(address(vault), 3 ether);
        vm.deal(address(weth), 3 ether);

        vm.prank(owner);
        vault.send(payee, address(0), 1 ether, new address[](0), new uint256[](0));
        assertEq(payee.balance, 1 ether, "the payee got ETH, not WETH");
    }

    function test_aRecipientThatRefusesEthFailsTheSend() public {
        RejectsEth hostile = new RejectsEth();
        weth.mint(address(vault), 3 ether);
        vm.deal(address(weth), 3 ether);

        vm.prank(owner);
        vm.expectRevert(TransferFailed.selector);
        vault.send(address(hostile), address(0), 1 ether, new address[](0), new uint256[](0));
    }

    function test_anEthSendLargerThanTheWrappedBalanceIsRefused() public {
        weth.mint(address(vault), 1 ether);
        vm.deal(address(weth), 1 ether);

        vm.prank(owner);
        vm.expectRevert();
        vault.send(payee, address(0), 2 ether, new address[](0), new uint256[](0));
        assertEq(payee.balance, 0, "the unwrap failed before anything left");
    }

    // ── a proposal is validated against the owner's caps, at proposal time ────
    //
    // The single-recipient path is the one an operator actually reaches: `send` from an operator
    // becomes proposeSendOne, which runs the same cap checks the owner's own send would. Validating
    // here rather than at approval means the owner never has to reason about whether approving a queued
    // proposal would breach a cap they set afterwards.

    function _cap(uint64 maxSendValue, uint64 interval) internal {
        vm.prank(owner);
        vault.updatePaymentRisk(
            IBittyV1Owner.PaymentRisk({
                maxSendValue: maxSendValue,
                maxSendInterval: interval,
                newPaymentProtection: type(uint256).max,
                changeTimelock: type(uint256).max
            })
        );
    }

    function test_aProposalToNobodyIsRefused() public {
        vm.prank(operator);
        vm.expectRevert(AddressZero.selector);
        vault.send(address(0), address(usdc), 1e6, new address[](0), new uint256[](0));
    }

    function test_underACapAProposalMustNameAStablecoin() public {
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        guard.setAsset(address(wbtc), 2);
        wbtc.mint(address(vault), 10e8);
        _cap(1_000, type(uint64).max);

        vm.prank(operator);
        vm.expectRevert(PaymentNotStableCoin.selector);
        vault.send(payee, address(wbtc), 1e8, new address[](0), new uint256[](0));
    }

    function test_aProposalOverTheCapIsRefused() public {
        _cap(1_000, type(uint64).max);
        vm.prank(operator);
        vm.expectRevert(PaymentExceedsRiskCap.selector);
        vault.send(payee, address(usdc), 1_001e6, new address[](0), new uint256[](0));
    }

    function test_aProposalUnderTheCapIsAccepted() public {
        _cap(1_000, type(uint64).max);
        vm.prank(operator);
        vault.send(payee, address(usdc), 900e6, new address[](0), new uint256[](0));

        vm.prank(owner);
        vault.approveSend(0);
        assertEq(usdc.balanceOf(payee), 900e6, "within the cap, so it paid on approval");
    }

    /// The rolling window is the OWNER's own budget. A proposal does not consume it — only the owner
    /// spending does — so an operator queueing work cannot exhaust the owner's headroom.
    function test_aProposalDoesNotConsumeTheOwnersRollingBudget() public {
        _cap(1_000, 1 days);

        vm.prank(operator);
        vault.send(payee, address(usdc), 900e6, new address[](0), new uint256[](0));

        vm.prank(owner);
        vault.send(payee, address(usdc), 900e6, new address[](0), new uint256[](0));
        assertEq(usdc.balanceOf(payee), 900e6, "the owner still had their full window");
    }

    function test_theOwnersOwnSendStillHitsTheWindow() public {
        _cap(1_000, 1 days);
        vm.startPrank(owner);
        vault.send(payee, address(usdc), 900e6, new address[](0), new uint256[](0));
        vm.expectRevert(PaymentExceedsPeriodLimit.selector);
        vault.send(payee, address(usdc), 900e6, new address[](0), new uint256[](0));
        vm.stopPrank();
    }
}
