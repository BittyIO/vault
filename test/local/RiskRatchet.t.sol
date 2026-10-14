// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {PendingChanges, RiskTimelockTooLong} from "../../src/interfaces/IBittyV1Vault.sol";
import {RiskLogic} from "../../src/logic/RiskLogic.sol";
import {BITTY_GUARD, MAX_RISK_TIMELOCK} from "../../src/logic/Constants.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

/**
 * TWO KNOBS, AND THE RATCHET THAT GOVERNS BOTH.
 *
 * The vault used to expose four risk numbers — a protection window for new payees, a send cap, the
 * period that cap applied over, and the timelock on changing any of it. Four, where owners only ever
 * had two questions: how long before something new can touch my money, and how much can leave in a
 * day. The rest was the same question asked twice. A protection window and a change timelock are
 * both "how long do I get to notice", and once the answer is one number there is nothing left for the
 * period to vary independently of the cap.
 *
 * So: `timelock` and `sendDailyAllowance`.
 *
 * `timelock` is now the single wait in front of everything deferred — a new whitelisted recipient, a
 * new scheduled payment, an asset-manager grant, a handover of the vault, and every loosening of
 * these two numbers. One knob the owner can reason about: "I get N hours to see anything new."
 *
 * THE RATCHET is unchanged and is what the whole model rests on. Tightening applies immediately;
 * loosening waits out the timelock. It is what makes a compromised owner BOUNDED rather than
 * instant, because the one thing an attacker wants — a bigger allowance, a shorter wait — is the one
 * direction that cannot take effect today. Which way is "safer" still differs by knob:
 *
 *   timelock        — LOWER is looser (less time to notice)
 *   sendDailyAllowance  — a cap, where 0 means "no cap", so higher-or-zero is looser
 */
contract RiskRatchetTest is Test {
    BittyV1Vault vault;
    address owner = makeAddr("owner");
    address gasWrapped = makeAddr("gasWrapped");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));
    }

    function _risk(uint256 timelock, uint256 sendDailyAllowance) internal {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(timelock, sendDailyAllowance));
    }

    function _cfg() internal view returns (uint64 timelock, uint64 sendDailyAllowance) {
        return vault.riskSettings();
    }

    // ── the two directions ────────────────────────────────────────────────────

    // S-10: risk values are stored as uint64. A uint256 input above that range must REVERT, not silently
    // truncate — `sendDailyAllowance` wrapping to 0 would read as "no cap" and quietly disable the limit,
    // and any wrapped value is a risk control set to something the owner never asked for.
    function test_outOfRangeRiskValueRevertsInsteadOfTruncating() public {
        uint256 tooBig = uint256(type(uint64).max) + 1;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 64, tooBig));
        vault.updateRisk(IBittyV1Owner.RiskSettings(UNCHANGED, tooBig));
    }

    function test_tighteningAppliesImmediately() public {
        _risk(1 days, 1_000);

        // Both directions of tightening: a longer wait, and a smaller allowance.
        _risk(3 days, 500);
        (uint64 timelock, uint64 allowance) = _cfg();
        assertEq(timelock, 3 days, "a longer wait is safer, so it lands now");
        assertEq(allowance, 500, "and so is a smaller allowance");
    }

    function test_looseningIsDeferredByTheTimelock() public {
        _risk(1 days, 500);

        _risk(UNCHANGED, 5_000);
        (, uint64 allowance) = _cfg();
        assertEq(allowance, 500, "not yet: raising the allowance is what an attacker wants");

        vm.warp(block.timestamp + 1 days);
        (, allowance) = _cfg();
        assertEq(allowance, 5_000, "and it lands a day later, as the owner asked");
    }

    function test_clearingACapIsALoosening() public {
        _risk(1 days, 500);

        _risk(UNCHANGED, 0);
        (, uint64 allowance) = _cfg();
        assertEq(allowance, 500, "zero means no cap at all, so it waits like any other loosening");

        vm.warp(block.timestamp + 1 days);
        (, allowance) = _cfg();
        assertEq(allowance, 0, "no cap");
    }

    function test_shorteningTheWaitIsALoosening() public {
        _risk(3 days, UNCHANGED);

        _risk(1 hours, UNCHANGED);
        (uint64 timelock,) = _cfg();
        assertEq(timelock, 3 days, "a shorter wait gives the owner less time to notice");

        vm.warp(block.timestamp + 3 days);
        (timelock,) = _cfg();
        assertEq(timelock, 1 hours);
    }

    /**
     * The one that would unravel everything else. If shortening the timelock took effect at once, an
     * attacker would set it to zero and then loosen every other limit in the same transaction.
     */
    function test_theTimelockCannotBeShortenedToBypassItself() public {
        _risk(7 days, 500);

        _risk(0, UNCHANGED);
        (uint64 timelock,) = _cfg();
        assertEq(timelock, 7 days, "still a week");

        // And while that is pending, a loosening still waits out the OLD value.
        _risk(UNCHANGED, 9_000);
        vm.warp(block.timestamp + 1 days);
        (, uint64 allowance) = _cfg();
        assertEq(allowance, 500, "a day is not a week");

        vm.warp(block.timestamp + 6 days);
        (timelock, allowance) = _cfg();
        assertEq(timelock, 0, "the wait is gone now");
        assertEq(allowance, 9_000, "and the loosening landed on the old schedule, not the new one");
    }

    function test_lengtheningTheTimelockIsImmediate() public {
        _risk(1 hours, UNCHANGED);
        _risk(30 days, UNCHANGED);
        (uint64 timelock,) = _cfg();
        assertEq(timelock, 30 days, "more time to notice is always safe");
    }

    function test_aTighteningCancelsAPendingLoosening() public {
        _risk(2 days, 500);
        _risk(UNCHANGED, 5_000);

        _risk(UNCHANGED, 100);
        vm.warp(block.timestamp + 10 days);
        (, uint64 allowance) = _cfg();
        assertEq(allowance, 100, "the queued loosening is gone, not merely postponed");
    }

    function test_withoutATimelockEverythingIsImmediate() public {
        _risk(UNCHANGED, 500);
        _risk(UNCHANGED, 9_000);
        (, uint64 allowance) = _cfg();
        assertEq(allowance, 9_000, "a vault given no wait has nothing to wait for");
    }

    /**
     * A MONTH, not ten years, and the cap is a security bound rather than a usability one.
     *
     * Lengthening this number is a tightening, so it lands instantly; shortening it is a loosening
     * and waits out the value being replaced. A stolen key can therefore set it as high as the cap
     * allows in ONE call, and nobody can bring it down again until it has run — not the real owner,
     * and not {BittyV1Vault-emergencyLock}, which voids changes that are still pending while this
     * one already applied. The ceiling is how long that griefing can last.
     *
     * It is also how long an owner waits to add a payee, so the same number has to stay usable.
     */
    function test_theTimelockIsBounded() public {
        vm.prank(owner);
        vm.expectRevert(RiskTimelockTooLong.selector);
        vault.updateRisk(IBittyV1Owner.RiskSettings(uint256(MAX_RISK_TIMELOCK) + 1, UNCHANGED));

        assertEq(MAX_RISK_TIMELOCK, 30 days, "a month");

        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(MAX_RISK_TIMELOCK, UNCHANGED));
        (uint64 timelock,) = _cfg();
        assertEq(timelock, 30 days, "the cap itself is allowed");
    }

    /**
     * The attack the cap bounds, played out: the key sets the longest wait it can, and the owner
     * cannot undo it for exactly that long.
     */
    function test_aStolenKeyCanFreezeTheWaitOnlyForTheCappedPeriod() public {
        _risk(1 days, 500);

        vm.prank(owner); // the leaked key
        vault.updateRisk(IBittyV1Owner.RiskSettings(MAX_RISK_TIMELOCK, UNCHANGED));
        (uint64 timelock,) = _cfg();
        assertEq(timelock, 30 days, "a tightening, so it landed at once and unasked");

        // The real owner wants it back. Shortening is a loosening, so it waits out the new value.
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(1 days, UNCHANGED));
        vm.warp(block.timestamp + 30 days - 1);
        (timelock,) = _cfg();
        assertEq(timelock, 30 days, "still stuck, and nothing can hurry it");

        vm.warp(block.timestamp + 1);
        (timelock,) = _cfg();
        assertEq(timelock, 1 days, "and a month is the whole of the damage");
    }

    function test_unchangedFieldsAreLeftAlone() public {
        _risk(2 days, 777);
        _risk(UNCHANGED, UNCHANGED);
        (uint64 timelock, uint64 allowance) = _cfg();
        assertEq(timelock, 2 days);
        assertEq(allowance, 777);
    }

    function test_onlyOwnerMayChangeRisk() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        vault.updateRisk(IBittyV1Owner.RiskSettings(1 days, UNCHANGED));
    }

    /**
     * A loosening whose wait has elapsed is in force whether or not anything wrote since. The next
     * write has to notice that and bank it, otherwise it would compare against a value that is no
     * longer live and mis-classify the new setting's direction.
     */
    function test_aMaturedLooseningIsSettledByTheNextWrite() public {
        _risk(1 days, 500);
        _risk(UNCHANGED, 5_000);
        vm.warp(block.timestamp + 1 days);

        // 3_000 is a TIGHTENING against the 5_000 now in force, so it must apply at once.
        _risk(UNCHANGED, 3_000);
        (, uint64 allowance) = _cfg();
        assertEq(allowance, 3_000, "banked 5_000 first, then tightened to 3_000 immediately");
    }

    function test_aMaturedWaitLooseningIsSettledByTheNextWrite() public {
        _risk(10 days, UNCHANGED);
        _risk(2 days, UNCHANGED);
        vm.warp(block.timestamp + 10 days);

        _risk(5 days, UNCHANGED);
        (uint64 timelock,) = _cfg();
        assertEq(timelock, 5 days, "2 days was live, so 5 days is a tightening and lands now");
    }

    // ── what the one knob now governs ─────────────────────────────────────────

    /**
     * The point of the collapse. One number stands in front of everything deferred, so an owner who
     * sets "a day" gets a day's warning on a new payee, a new delegate and a handover alike — rather
     * than having to discover that two different numbers governed two of those three.
     */
    function test_theOneTimelockGovernsEveryDeferredChange() public {
        _risk(2 days, UNCHANGED);
        address stranger = makeAddr("stranger");

        // a new destination
        vm.prank(owner);
        uint256 id = vault.addWhitelistedRecipient(stranger, address(0));

        // a new delegate
        vm.prank(owner);
        BittyV1VaultDeFiFacet(payable(address(vault))).setAssetManager(stranger, 0, 1);

        // and the vault itself
        vm.prank(owner);
        vault.transferOwnership(stranger);

        PendingChanges memory p = vault.pendingChanges();
        assertEq(p.newAssetManagerAt, block.timestamp + 2 days, "the delegate waits two days");
        assertEq(p.newOwnerReadyAt, uint64(block.timestamp + 2 days), "so does the handover");
        // The destination is not in this view at all — deferred additions are unbounded in number
        // and belong to the client, which lists them from the events that created them. What the
        // chain owes here is the enforcement: it is not payable yet.
        vm.prank(owner);
        vm.expectRevert();
        vault.sendToWhitelistedRecipient(id, address(0), 1, new address[](0), new uint256[](0));
    }

    /// A pending loosening shows up in the one read the owner is meant to be watching.
    function test_aPendingLooseningIsReportedToTheOwner() public {
        _risk(2 days, 500);
        _risk(UNCHANGED, 9_000);

        PendingChanges memory p = vault.pendingChanges();
        assertEq(p.sendDailyAllowance, 9_000, "someone is trying to raise the allowance");
        assertEq(p.sendDailyAllowanceAt, uint64(block.timestamp + 2 days));
        assertEq(p.timelockAt, 0, "and nothing is being done to the wait itself");
    }

    function test_aTighteningIsNeverReportedAsPending() public {
        _risk(2 days, 500);
        _risk(5 days, 100);

        PendingChanges memory p = vault.pendingChanges();
        assertEq(p.timelockAt, 0);
        assertEq(p.sendDailyAllowanceAt, 0, "both already applied, so there is nothing to warn about");
    }
}
