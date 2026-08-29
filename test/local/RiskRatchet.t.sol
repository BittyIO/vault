// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {PaymentProtectionTooLong} from "../../src/interfaces/IBittyV1Vault.sol";
import {RiskLogic} from "../../src/logic/RiskLogic.sol";
import {BITTY_GUARD, MAX_DURATION} from "../../src/logic/Constants.sol";

/**
 * THE RATCHET. Tightening applies immediately; loosening waits out `changeTimelock`.
 *
 * This is the property the whole risk model rests on: it is what makes a compromised owner BOUNDED
 * rather than instant, because the one thing an attacker wants — raising a cap, shortening a window,
 * removing a limit — is the one direction that cannot take effect today. If it silently stopped
 * ratcheting, every control below would still read back plausible values while enforcing nothing.
 *
 * The asymmetry is per-field, because "safer" points in different directions:
 *   newPaymentProtection / maxSendInterval / changeTimelock  — LOWER is looser
 *   maxSendValue                                             — a cap where 0 means "no cap"
 */
contract RiskRatchetTest is Test {
    BittyV1Vault vault;
    address owner = makeAddr("owner");
    address weth = makeAddr("weth");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));
    }

    function _risk(uint256 prot, uint256 maxSend, uint256 interval, uint256 timelock) internal {
        vm.prank(owner);
        vault.updatePaymentRisk(IBittyV1Owner.PaymentRisk(prot, maxSend, interval, timelock));
    }

    function _cfg() internal view returns (uint64 prot, uint64 maxSend, uint64 timelock, uint64 interval) {
        return vault.getRiskConfig();
    }

    // ── the two directions ────────────────────────────────────────────────────

    /// Tightening is immediate. Someone reacting to something alarming is never made to wait.
    function test_tighteningAppliesImmediately() public {
        _risk(UNCHANGED, UNCHANGED, UNCHANGED, 2 days); // arm the timelock first
        _risk(UNCHANGED, 1000, UNCHANGED, UNCHANGED); // set a cap: tightening from "no cap"
        (, uint64 maxSend,,) = _cfg();
        assertEq(maxSend, 1000, "a cap where there was none takes effect now");

        _risk(UNCHANGED, 100, UNCHANGED, UNCHANGED); // lower the cap
        (, maxSend,,) = _cfg();
        assertEq(maxSend, 100, "lowering a cap takes effect now");
    }

    /// Loosening waits. This is the half an attacker needs and cannot have.
    function test_looseningIsDeferredByTheTimelock() public {
        _risk(UNCHANGED, UNCHANGED, UNCHANGED, 2 days);
        _risk(UNCHANGED, 100, UNCHANGED, UNCHANGED);

        _risk(UNCHANGED, 10_000, UNCHANGED, UNCHANGED); // raise the cap
        (, uint64 maxSend,,) = _cfg();
        assertEq(maxSend, 100, "still the old, tighter cap");

        vm.warp(block.timestamp + 2 days - 1);
        (, maxSend,,) = _cfg();
        assertEq(maxSend, 100, "one second before the deadline, still tight");

        vm.warp(block.timestamp + 1);
        (, maxSend,,) = _cfg();
        assertEq(maxSend, 10_000, "and only then does it loosen");
    }

    /// Clearing a cap entirely (0 = no cap) is the largest loosening there is, so it waits too.
    function test_clearingACapIsALoosening() public {
        _risk(UNCHANGED, UNCHANGED, UNCHANGED, 2 days);
        _risk(UNCHANGED, 100, UNCHANGED, UNCHANGED);

        _risk(UNCHANGED, 0, UNCHANGED, UNCHANGED);
        (, uint64 maxSend,,) = _cfg();
        assertEq(maxSend, 100, "0 means unlimited, so it cannot be immediate");

        vm.warp(block.timestamp + 2 days);
        (, maxSend,,) = _cfg();
        assertEq(maxSend, 0, "unlimited only after the wait");
    }

    /// For a window, LOWER is looser — the opposite direction from a cap, same rule.
    function test_shorteningAProtectionWindowIsALoosening() public {
        _risk(UNCHANGED, UNCHANGED, UNCHANGED, 2 days);
        _risk(7 days, UNCHANGED, UNCHANGED, UNCHANGED);
        (uint64 prot,,,) = _cfg();
        assertEq(prot, 7 days, "lengthening a window is tightening: immediate");

        _risk(1 days, UNCHANGED, UNCHANGED, UNCHANGED);
        (prot,,,) = _cfg();
        assertEq(prot, 7 days, "shortening waits");

        vm.warp(block.timestamp + 2 days);
        (prot,,,) = _cfg();
        assertEq(prot, 1 days, "then applies");
    }

    // ── the timelock protecting itself ────────────────────────────────────────

    /**
     * The attack the ratchet would otherwise be wide open to: shorten the delay first, then loosen
     * everything else instantly. Shortening the timelock is itself a loosening, so it waits out the
     * OLD value — an attacker cannot buy speed with their first transaction.
     */
    function test_theTimelockCannotBeShortenedToBypassItself() public {
        _risk(UNCHANGED, UNCHANGED, UNCHANGED, 7 days);
        _risk(UNCHANGED, 100, UNCHANGED, UNCHANGED);

        _risk(UNCHANGED, UNCHANGED, UNCHANGED, 0); // try to drop the delay
        (,, uint64 timelock,) = _cfg();
        assertEq(timelock, 7 days, "still 7 days");

        // And a loosening attempted now is still held for the full original delay.
        _risk(UNCHANGED, 10_000, UNCHANGED, UNCHANGED);
        vm.warp(block.timestamp + 7 days - 1);
        (, uint64 maxSend,,) = _cfg();
        assertEq(maxSend, 100, "the cap did not loosen early");
    }

    /**
     * Lengthening the delay is a TIGHTENING, so it lands at once — and the pending loosening it
     * overwrote is discarded rather than kept.
     */
    function test_lengtheningTheTimelockIsImmediate() public {
        _risk(UNCHANGED, UNCHANGED, UNCHANGED, 1 days);
        _risk(UNCHANGED, UNCHANGED, UNCHANGED, 30 days);
        (,, uint64 timelock,) = _cfg();
        assertEq(timelock, 30 days, "raising the delay is immediate");
    }

    // ── settle / overwrite semantics ──────────────────────────────────────────

    /// A tightening while a loosening is pending KILLS the pending one — it must not resurface.
    function test_aTighteningCancelsAPendingLoosening() public {
        _risk(UNCHANGED, UNCHANGED, UNCHANGED, 2 days);
        _risk(UNCHANGED, 100, UNCHANGED, UNCHANGED);

        _risk(UNCHANGED, 10_000, UNCHANGED, UNCHANGED); // queue a loosening
        _risk(UNCHANGED, 50, UNCHANGED, UNCHANGED); // then tighten instead

        (, uint64 maxSend,,) = _cfg();
        assertEq(maxSend, 50, "the tightening is live");

        vm.warp(block.timestamp + 30 days);
        (, maxSend,,) = _cfg();
        assertEq(maxSend, 50, "and the abandoned loosening never arrives");
    }

    /// With no timelock configured, everything is immediate — the ratchet is opt-in.
    function test_withoutATimelockEverythingIsImmediate() public {
        _risk(UNCHANGED, 100, UNCHANGED, UNCHANGED);
        _risk(UNCHANGED, 10_000, UNCHANGED, UNCHANGED);
        (, uint64 maxSend,,) = _cfg();
        assertEq(maxSend, 10_000, "no delay configured, so nothing is deferred");
    }

    // ── bounds and access ─────────────────────────────────────────────────────

    function test_protectionWindowIsBounded() public {
        vm.prank(owner);
        vm.expectRevert(PaymentProtectionTooLong.selector);
        vault.updatePaymentRisk(IBittyV1Owner.PaymentRisk(uint256(MAX_DURATION) + 1, UNCHANGED, UNCHANGED, UNCHANGED));
    }

    /// The sentinel means "leave this one alone", so a partial update cannot silently reset the rest.
    function test_unchangedFieldsAreLeftAlone() public {
        _risk(3 days, 500, 1 days, 2 days);
        _risk(UNCHANGED, UNCHANGED, UNCHANGED, UNCHANGED);
        (uint64 prot, uint64 maxSend, uint64 timelock, uint64 interval) = _cfg();
        assertEq(prot, 3 days);
        assertEq(maxSend, 500);
        assertEq(timelock, 2 days);
        assertEq(interval, 1 days);
    }

    function test_onlyOwnerMayChangeRisk() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        vault.updatePaymentRisk(IBittyV1Owner.PaymentRisk(1 days, UNCHANGED, UNCHANGED, UNCHANGED));
    }

    /**
     * A matured pending change is folded into the live value by the NEXT write, not only by reads.
     * Without that, the write would compare against the stale value and could misclassify a tightening
     * as a loosening — deferring a change the owner is entitled to have immediately.
     */
    function test_aMaturedLooseningIsSettledByTheNextWrite() public {
        _risk(UNCHANGED, UNCHANGED, UNCHANGED, 2 days);
        _risk(UNCHANGED, 100, UNCHANGED, UNCHANGED);
        _risk(UNCHANGED, 10_000, UNCHANGED, UNCHANGED);

        vm.warp(block.timestamp + 2 days);
        (, uint64 maxSend,,) = _cfg();
        assertEq(maxSend, 10_000, "matured");

        _risk(UNCHANGED, 5_000, UNCHANGED, UNCHANGED);
        (, maxSend,,) = _cfg();
        assertEq(maxSend, 5_000, "measured against the settled 10,000, so this is a tightening");
    }

    function test_aMaturedWindowLooseningIsSettledByTheNextWrite() public {
        _risk(UNCHANGED, UNCHANGED, UNCHANGED, 2 days);
        _risk(10 days, UNCHANGED, UNCHANGED, UNCHANGED);
        _risk(1 days, UNCHANGED, UNCHANGED, UNCHANGED);

        vm.warp(block.timestamp + 2 days);
        (uint64 prot,,,) = _cfg();
        assertEq(prot, 1 days, "matured");

        _risk(3 days, UNCHANGED, UNCHANGED, UNCHANGED);
        (prot,,,) = _cfg();
        assertEq(prot, 3 days, "lengthening from the settled 1 day is a tightening, so immediate");
    }

    function test_aMaturedGasBudgetLooseningIsSettledByTheNextWrite() public {
        address[] memory none = new address[](0);
        _risk(UNCHANGED, UNCHANGED, UNCHANGED, 2 days);

        vm.startPrank(owner);
        vault.setGasless(none, 10, 5);
        vault.setGasless(none, 80, 5);
        vm.stopPrank();

        (, uint256 daily,) = vault.gaslessConfig();
        assertEq(daily, 10, "raising the ceiling waits");

        vm.warp(block.timestamp + 2 days);
        (, daily,) = vault.gaslessConfig();
        assertEq(daily, 80, "matured");

        vm.prank(owner);
        vault.setGasless(none, 40, 5);
        (, daily,) = vault.gaslessConfig();
        assertEq(daily, 40, "lowering from the settled 80 is a tightening, so immediate");
    }
}
