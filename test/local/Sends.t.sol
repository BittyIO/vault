// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {
    AddressZero,
    AmountIsZero,
    PaymentNotStableCoin,
    PaymentExceedsRiskCap,
    PaymentExceedsPeriodLimit
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * One-off sends, and the two limits an owner can put on themselves.
 *
 * `sendDailyAllowance` bounds a single transaction AND the day's total, which is one number doing both
 * jobs: it exists so a compromised owner key is rate-limited rather than instant, and the day it
 * takes to spend the next tranche is the time the real owner has to notice and lock.
 */
contract SendsTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 other;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address payee = makeAddr("payee");
    address gasWrapped = makeAddr("gasWrapped");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        other = new MockERC20("Other", "OTH", 18);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 100_000e6);
        other.mint(address(vault), 100_000e18);
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
        vault.updateRisk(IBittyV1Owner.RiskSettings(UNCHANGED, c));
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

    // ── the rolling day ───────────────────────────────────────────────────────

    /**
     * The cap is a budget per DAY rather than per transaction, so a compromised key cannot simply
     * repeat a permitted send until the vault is empty.
     *
     * The period used to be a fifth risk number the owner set alongside the cap. It is a day now and
     * cannot be set: a cap with a settable period is two numbers answering one question, and an
     * owner who wants less out per day says so in the cap. A vault configured with a longer period
     * before the collapse keeps it, since the same cap over a week lets less out than over a day —
     * see {TimelockLib-sendPeriod}.
     */
    function test_theSendDailyAllowanceLimitsTotalOutflowNotJustOneSend() public {
        _cap(1000);

        _send(owner, payee, address(usdc), 600e6);
        vm.prank(owner);
        vm.expectRevert(PaymentExceedsPeriodLimit.selector);
        vault.send(payee, address(usdc), 500e6, new address[](0), new uint256[](0));

        _send(owner, payee, address(usdc), 400e6); // exactly fills the window
        assertEq(usdc.balanceOf(payee), 1000e6);
    }

    /// It ROLLS: the allowance refills on its own once the day has passed.
    function test_theSendDailyAllowanceRefillsAfterADay() public {
        _cap(1000);
        _send(owner, payee, address(usdc), 1000e6);

        vm.prank(owner);
        vm.expectRevert(PaymentExceedsPeriodLimit.selector);
        vault.send(payee, address(usdc), 1e6, new address[](0), new uint256[](0));

        vm.warp(block.timestamp + 1 days);
        _send(owner, payee, address(usdc), 1000e6);
        assertEq(usdc.balanceOf(payee), 2000e6, "a fresh day, a fresh budget");
    }

    // ── access and input ──────────────────────────────────────────────────────

    function test_strangersCannotSend() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, makeAddr("stranger"))
        );
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
}
