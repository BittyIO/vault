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
    NotPayoutOperator,
    PaymentNotApproved,
    NotPendingApproval,
    ProtectionPeriodNotEnded,
    WhitelistedRecipientNotFound,
    WhitelistedRecipientAssetNotAllowed,
    WhitelistedRecipientContentMismatch
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * Whitelisted recipients: standing payees the owner can pay on demand.
 *
 * Two protections stack, and they answer different threats. A PROTECTION WINDOW delays a newly added
 * payee, so a compromised key cannot add a destination and drain to it in the same session. An
 * APPROVAL gate holds anything a payout operator proposes until the owner confirms it — bound to the
 * exact content they reviewed, so a proposer cannot swap the address after approval is requested.
 */
contract WhitelistTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 other;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address payee = makeAddr("payee");
    address weth = makeAddr("weth");

    uint256 constant UNCHANGED = type(uint256).max;

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
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 1_000e6);
        other.mint(address(vault), 1_000e18);

        vm.prank(owner);
        vault.updatePayoutOperator(operator, true);
    }

    function _hash(address recipient, address allowedAsset) internal pure returns (bytes32) {
        return keccak256(abi.encode(IBittyV1Vault.WhitelistedRecipient(recipient, allowedAsset)));
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    // ── the happy path ────────────────────────────────────────────────────────

    function test_ownerAddsAndPays() public {
        vm.startPrank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee, address(usdc));
        _pay(id, address(usdc), 10e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(payee), 10e6);
    }

    /// An entry with no named asset accepts any asset the vault holds.
    function test_anyAssetWhenNoneIsNamed() public {
        vm.startPrank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee, address(0));
        _pay(id, address(usdc), 1e6);
        _pay(id, address(other), 1e18);
        vm.stopPrank();
        assertEq(usdc.balanceOf(payee), 1e6);
        assertEq(other.balanceOf(payee), 1e18);
    }

    /// A named asset is a restriction, not a default.
    function test_namedAssetIsEnforced() public {
        vm.startPrank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee, address(usdc));
        vm.expectRevert(WhitelistedRecipientAssetNotAllowed.selector);
        _pay(id, address(other), 1e18);
        vm.stopPrank();
    }

    // ── the protection window ─────────────────────────────────────────────────

    /**
     * A new payee cannot be paid immediately once a window is configured. This is what stops a
     * compromised key adding a destination and draining to it in the same session — the owner has the
     * whole window to notice and remove it.
     */
    function test_aNewPayeeWaitsOutTheProtectionWindow() public {
        vm.startPrank(owner);
        vault.updatePaymentRisk(IBittyV1Owner.PaymentRisk(3 days, UNCHANGED, UNCHANGED, UNCHANGED));
        uint256 id = vault.addWhitelistedRecipient(payee, address(usdc));

        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        _pay(id, address(usdc), 1e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        _pay(id, address(usdc), 1e6);
        assertEq(usdc.balanceOf(payee), 1e6, "payable once the window has run");
    }

    // ── operator proposals ────────────────────────────────────────────────────

    /// A payout operator PROPOSES; nothing can be paid until the owner approves.
    function test_operatorProposalIsUnpayableUntilApproved() public {
        vm.prank(operator);
        uint256 id = vault.addWhitelistedRecipient(payee, address(usdc));

        vm.prank(owner);
        vm.expectRevert(PaymentNotApproved.selector);
        _pay(id, address(usdc), 1e6);

        vm.prank(owner);
        vault.reviewWhitelistedRecipients(_one(id), _hashes(_hash(payee, address(usdc))), new uint256[](0));

        vm.prank(owner);
        _pay(id, address(usdc), 1e6);
        assertEq(usdc.balanceOf(payee), 1e6);
    }

    /**
     * Approval is bound to the exact content reviewed. A proposer who changes the address after the
     * owner has been asked to approve gets a mismatch, not a signature on the new value.
     */
    function test_approvalIsBoundToTheContentReviewed() public {
        vm.prank(operator);
        uint256 id = vault.addWhitelistedRecipient(payee, address(usdc));

        address attacker = makeAddr("attacker");
        vm.prank(operator);
        vault.updateWhitelistedRecipients(_one(id), _addrs(attacker), _addrs(address(usdc)));

        // The owner approves what they were shown; the stored entry no longer matches it.
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientContentMismatch.selector);
        vault.reviewWhitelistedRecipients(_one(id), _hashes(_hash(payee, address(usdc))), new uint256[](0));
    }

    /// The owner's own additions need no approval — there is nobody else to confirm them.
    function test_ownersOwnEntryNeedsNoApproval() public {
        vm.prank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee, address(usdc));
        vm.prank(owner);
        vm.expectRevert(NotPendingApproval.selector);
        vault.reviewWhitelistedRecipients(_one(id), _hashes(_hash(payee, address(usdc))), new uint256[](0));
    }

    /// The owner can cancel a proposal outright instead of approving it.
    function test_ownerCancelsAProposal() public {
        vm.prank(operator);
        uint256 id = vault.addWhitelistedRecipient(payee, address(usdc));
        vm.prank(owner);
        vault.reviewWhitelistedRecipients(new uint256[](0), new bytes32[](0), _one(id));

        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        _pay(id, address(usdc), 1e6);
    }

    // ── access ────────────────────────────────────────────────────────────────

    function test_strangersCannotTouchTheList() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(NotPayoutOperator.selector);
        vault.addWhitelistedRecipient(payee, address(usdc));
    }

    /// Paying is the OWNER's act, never the operator's — proposing is as far as an operator goes.
    function test_operatorCannotPay() public {
        vm.prank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee, address(usdc));
        vm.prank(operator);
        vm.expectRevert();
        _pay(id, address(usdc), 1e6);
    }

    function test_onlyOwnerMayReview() public {
        vm.prank(operator);
        uint256 id = vault.addWhitelistedRecipient(payee, address(usdc));
        vm.prank(operator);
        vm.expectRevert();
        vault.reviewWhitelistedRecipients(_one(id), _hashes(_hash(payee, address(usdc))), new uint256[](0));
    }

    // ── bad input ─────────────────────────────────────────────────────────────

    function test_zeroRecipientRejected() public {
        vm.prank(owner);
        vm.expectRevert(AddressZero.selector);
        vault.addWhitelistedRecipient(address(0), address(usdc));
    }

    function test_zeroAmountRejected() public {
        vm.startPrank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee, address(usdc));
        vm.expectRevert(AmountIsZero.selector);
        _pay(id, address(usdc), 0);
        vm.stopPrank();
    }

    function test_unknownIdRejected() public {
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        _pay(999, address(usdc), 1e6);
    }

    function test_removedEntryCannotBePaid() public {
        vm.startPrank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee, address(usdc));
        vault.removeWhitelistedRecipients(_one(id));
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        _pay(id, address(usdc), 1e6);
        vm.stopPrank();
    }

    function test_getWhitelistedRecipientsReadsBack() public {
        vm.prank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee, address(usdc));
        (address[] memory rs, address[] memory as_) = vault.getWhitelistedRecipients(_one(id));
        assertEq(rs[0], payee);
        assertEq(as_[0], address(usdc));
    }

    /// Pay with no position-withdrawal legs: the arrays name where the money is pulled FROM, and
    /// these tests are all about the whitelist rules, not the funding source.
    function _pay(uint256 id, address asset, uint256 amount) internal {
        vault.sendToWhitelistedRecipient(id, asset, amount, new address[](0), new uint256[](0));
    }

    function _addrs(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _hashes(bytes32 h) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = h;
    }
}
