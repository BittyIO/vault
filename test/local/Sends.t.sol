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
    NotPayoutOperator,
    PaymentNotStableCoin,
    PaymentExceedsRiskCap,
    PaymentExceedsPeriodLimit
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * One-off sends, and the two limits an owner can put on themselves.
 *
 * `maxSendValue` bounds a single transaction; `maxSendInterval` turns it into a rolling budget. Both
 * exist so a compromised owner key is rate-limited rather than instant — the delay window is what the
 * real owner uses to notice and react.
 */
contract SendsTest is Test {
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
        usdc.mint(address(vault), 100_000e6);
        other.mint(address(vault), 100_000e18);

        vm.prank(owner);
        vault.updatePayoutOperator(operator, true);
    }

    function _send(address as_, address to, address asset, uint256 amount) internal {
        vm.prank(as_);
        vault.send(to, asset, amount, new address[](0), new uint256[](0));
    }

    function _batch(address as_, address[] memory tos, address[] memory assets, uint256[] memory amts) internal {
        vm.prank(as_);
        vault.batchSend(tos, assets, amts, new address[][](0), new uint256[][](0));
    }

    function _cap(uint256 c) internal {
        vm.prank(owner);
        vault.updatePaymentRisk(IBittyV1Owner.PaymentRisk(UNCHANGED, c, UNCHANGED, UNCHANGED));
    }

    function _window(uint256 w) internal {
        vm.prank(owner);
        vault.updatePaymentRisk(IBittyV1Owner.PaymentRisk(UNCHANGED, UNCHANGED, w, UNCHANGED));
    }

    // ── the unrestricted default ──────────────────────────────────────────────

    /// With no cap set, any asset may be sent in any amount. The limits are opt-in.
    function test_uncappedVaultSendsAnything() public {
        _send(owner, payee, address(other), 5e18);
        assertEq(other.balanceOf(payee), 5e18, "a non-stable asset is fine when no cap applies");
    }

    // ── the per-transaction cap ───────────────────────────────────────────────

    function test_capBoundsASingleSend() public {
        _cap(1000);
        _send(owner, payee, address(usdc), 1000e6);
        assertEq(usdc.balanceOf(payee), 1000e6, "at the cap is allowed");

        vm.prank(owner);
        vm.expectRevert(PaymentExceedsRiskCap.selector);
        vault.send(payee, address(usdc), 1001e6, new address[](0), new uint256[](0));
    }

    /**
     * Once a cap applies, only stable coins may be sent. The cap is a whole-token dollar figure, and
     * it cannot bound something whose value it has no way to read.
     */
    function test_underACapOnlyStableCoinsMayBeSent() public {
        _cap(1000);
        vm.prank(owner);
        vm.expectRevert(PaymentNotStableCoin.selector);
        vault.send(payee, address(other), 1e18, new address[](0), new uint256[](0));
    }

    /**
     * The cap applies to the BATCH TOTAL, not to each leg. Otherwise ten sends each at the cap would
     * move ten times the cap in one transaction, which is the whole thing the cap exists to stop.
     */
    function test_capAppliesToTheBatchTotalNotEachLeg() public {
        _cap(1000);
        address[] memory tos = new address[](2);
        address[] memory assets = new address[](2);
        uint256[] memory amts = new uint256[](2);
        tos[0] = payee;
        tos[1] = makeAddr("payee2");
        assets[0] = address(usdc);
        assets[1] = address(usdc);
        amts[0] = 600e6;
        amts[1] = 600e6; // each under the cap, 1200 together

        vm.prank(owner);
        vm.expectRevert(PaymentExceedsRiskCap.selector);
        vault.batchSend(tos, assets, amts, new address[][](0), new uint256[][](0));

        amts[1] = 400e6; // 1000 exactly
        _batch(owner, tos, assets, amts);
        assertEq(usdc.balanceOf(payee), 600e6);
    }

    // ── the rolling window ────────────────────────────────────────────────────

    /**
     * With an interval, the cap becomes a budget PER WINDOW rather than per transaction — so a
     * compromised key cannot simply repeat a permitted send until the vault is empty.
     */
    function test_theWindowLimitsTotalOutflowNotJustOneSend() public {
        _cap(1000);
        _window(1 days);

        _send(owner, payee, address(usdc), 600e6);
        vm.prank(owner);
        vm.expectRevert(PaymentExceedsPeriodLimit.selector);
        vault.send(payee, address(usdc), 500e6, new address[](0), new uint256[](0));

        _send(owner, payee, address(usdc), 400e6); // exactly fills the window
        assertEq(usdc.balanceOf(payee), 1000e6);
    }

    /// It is a ROLLING window: it refills on its own once the interval has passed.
    function test_theWindowRefillsAfterTheInterval() public {
        _cap(1000);
        _window(1 days);
        _send(owner, payee, address(usdc), 1000e6);

        vm.prank(owner);
        vm.expectRevert(PaymentExceedsPeriodLimit.selector);
        vault.send(payee, address(usdc), 1e6, new address[](0), new uint256[](0));

        vm.warp(block.timestamp + 1 days);
        _send(owner, payee, address(usdc), 1000e6);
        assertEq(usdc.balanceOf(payee), 2000e6, "a fresh window, a fresh budget");
    }

    // ── proposals ─────────────────────────────────────────────────────────────

    /// A payout operator's send is a PROPOSAL: nothing moves until the owner approves it.
    function test_operatorProposesAndOwnerApproves() public {
        vm.prank(operator);
        vault.send(payee, address(usdc), 10e6, new address[](0), new uint256[](0));
        assertEq(usdc.balanceOf(payee), 0, "nothing moved yet");

        vm.prank(owner);
        vault.approveSend(0);
        assertEq(usdc.balanceOf(payee), 10e6, "the owner released it");
    }

    function test_ownerCancelsAProposedSend() public {
        vm.prank(operator);
        vault.send(payee, address(usdc), 10e6, new address[](0), new uint256[](0));
        vm.prank(owner);
        vault.cancelSend(0);

        vm.prank(owner);
        vm.expectRevert();
        vault.approveSend(0);
        assertEq(usdc.balanceOf(payee), 0);
    }

    function test_operatorCannotApproveTheirOwnProposal() public {
        vm.prank(operator);
        vault.send(payee, address(usdc), 10e6, new address[](0), new uint256[](0));
        vm.prank(operator);
        vm.expectRevert();
        vault.approveSend(0);
    }

    // ── access and input ──────────────────────────────────────────────────────

    function test_strangersCannotSend() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotPayoutOperator.selector);
        vault.send(payee, address(usdc), 1e6, new address[](0), new uint256[](0));
    }

    function test_zeroRecipientAndAmountRejected() public {
        vm.startPrank(owner);
        vm.expectRevert(AddressZero.selector);
        vault.send(address(0), address(usdc), 1e6, new address[](0), new uint256[](0));
        vm.expectRevert(AmountIsZero.selector);
        vault.send(payee, address(usdc), 0, new address[](0), new uint256[](0));
        vm.stopPrank();
    }

    function test_payoutOperatorCannotAlsoBeTheOwner() public {
        vm.prank(owner);
        vm.expectRevert();
        vault.updatePayoutOperator(owner, true);
    }

    function test_ownerCanRemoveAnOperator() public {
        vm.prank(owner);
        vault.updatePayoutOperator(operator, false);
        vm.prank(operator);
        vm.expectRevert(NotPayoutOperator.selector);
        vault.send(payee, address(usdc), 1e6, new address[](0), new uint256[](0));
    }
}
