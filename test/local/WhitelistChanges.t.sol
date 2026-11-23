// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {
    ProtectionPeriodNotEnded,
    VaultLocked,
    WhitelistedRecipientNotFound
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, MIN_RISK_TIMELOCK} from "../../src/logic/Constants.sol";

/**
 * Taking a whitelisted recipient away waits, like granting one does.
 *
 * A whitelisted recipient is the owner's way out after a key leaks: a lock stops every other payment,
 * but not these. If removal were instant, a thief's first call would empty the list, and the forever
 * lock meant to save the vault would seal the money in it instead. So removing an entry the owner
 * can already pay queues behind the timelock, the entry stays payable until then, and a lock voids
 * whatever is still queued. There is no editing in place: a change is an addition and a removal.
 */
contract WhitelistChangesTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 other;

    address owner = makeAddr("owner");
    address cold = makeAddr("cold");
    address thief = makeAddr("thief");
    address newCold = makeAddr("newCold");
    address gasWrapped = makeAddr("gasWrapped");

    uint256 constant UNCHANGED = type(uint256).max;
    uint64 constant TIMELOCK = 3 days;
    /**
     * Every test starts here. Kept as a constant because under via-IR a local copy of
     * `block.timestamp` is re-read after a warp rather than remembered.
     */
    uint256 constant T0 = 1_000_000;

    uint256 coldId;

    function setUp() public {
        vm.warp(T0 - MIN_RISK_TIMELOCK);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)))
                ))
        );
        usdc = new MockERC20("USD Coin", "USDC", 6);
        other = new MockERC20("Other", "OTH", 18);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 100_000e6);
        other.mint(address(vault), 100e18);

        // Before anything goes wrong: one vetted destination, live by T0, and a timelock on what follows.
        vm.startPrank(owner);
        coldId = vault.addWhitelistedRecipient(cold);
        vm.warp(T0);
        vault.updateRisk(IBittyV1Owner.RiskSettings(TIMELOCK, UNCHANGED, UNCHANGED));
        vm.stopPrank();
    }

    // ── removal ───────────────────────────────────────────────────────────────

    function test_aRemovalWaitsAndTheEntryStaysPayableUntilThen() public {
        vm.expectEmit(address(vault));
        emit IBittyV1Owner.WhitelistedRecipientRemovalQueued(coldId, uint64(T0 + TIMELOCK));
        vm.prank(owner);
        vault.removeWhitelistedRecipients(_ids(coldId));

        uint64[] memory ats = vault.getWhitelistedRecipientRemovals(_ids(coldId));
        assertEq(ats[0], T0 + TIMELOCK, "when it lands");
        address[] memory rs = vault.getWhitelistedRecipients(_ids(coldId));
        assertEq(rs[0], cold, "still listed while it waits");

        vm.warp(T0 + TIMELOCK - 1);
        _pay(coldId, address(usdc), 1e6);
        assertEq(usdc.balanceOf(cold), 1e6, "still payable while the removal waits");

        vm.warp(T0 + TIMELOCK);
        rs = vault.getWhitelistedRecipients(_ids(coldId));
        assertEq(rs[0], address(0), "the read shows it gone once due");
        ats = vault.getWhitelistedRecipientRemovals(_ids(coldId));
        assertEq(ats[0], 0, "nothing left waiting");

        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.sendToWhitelistedRecipient(coldId, address(usdc), 1e6, _none(), _noAmounts());
    }

    function test_aDueRemovalIsAppliedByTheNextEdit() public {
        vm.prank(owner);
        vault.removeWhitelistedRecipients(_ids(coldId));
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.removeWhitelistedRecipients(_ids(coldId));
    }

    /**
     * The attack this exists for. The thief queues the removal of every destination, the owner
     * notices and locks — for ever, in the worst case — and the destinations are all still there.
     */
    function test_aForeverLockKeepsTheDestinationsAThiefTriedToRemove() public {
        vm.prank(owner);
        uint256 secondId = vault.addWhitelistedRecipient(newCold);
        vm.warp(block.timestamp + TIMELOCK);

        uint256[] memory both = new uint256[](2);
        both[0] = coldId;
        both[1] = secondId;
        vm.prank(owner); // the thief, holding the owner key
        vault.removeWhitelistedRecipients(both);

        vm.prank(owner);
        vault.foreverLock(coldId);

        vm.warp(block.timestamp + 365 days);
        _pay(coldId, address(usdc), 50_000e6);
        _pay(secondId, address(usdc), 50_000e6);
        assertEq(usdc.balanceOf(cold) + usdc.balanceOf(newCold), 100_000e6, "everything got out");

        address[] memory rs = vault.getWhitelistedRecipients(both);
        assertEq(rs[0], cold);
        assertEq(rs[1], newCold);
        uint64[] memory ats = vault.getWhitelistedRecipientRemovals(both);
        assertEq(ats[0], 0, "the voided removal is not shown as waiting");
        assertEq(ats[1], 0);

        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        vault.removeWhitelistedRecipients(both);
    }

    function test_anEmergencyLockVoidsAQueuedRemovalForGood() public {
        vm.prank(owner);
        vault.removeWhitelistedRecipients(_ids(coldId));
        vm.startPrank(owner);
        vault.emergencyLock();
        vault.unlock();
        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK * 10);
        _pay(coldId, address(usdc), 1e6);
        assertEq(usdc.balanceOf(cold), 1e6, "voided, not merely postponed");
    }

    function test_aRemovalThatLandedBeforeTheLockStands() public {
        vm.prank(owner);
        vault.removeWhitelistedRecipients(_ids(coldId));
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(owner);
        vault.emergencyLock();

        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.sendToWhitelistedRecipient(coldId, address(usdc), 1e6, _none(), _noAmounts());
    }

    /**
     * Nothing is taken from the owner by removing what nobody can pay yet — a thief's addition still
     * waiting out its window — so that goes at once.
     */
    function test_anEntryNotYetPayableIsRemovedAtOnce() public {
        vm.startPrank(owner);
        uint256 thiefId = vault.addWhitelistedRecipient(thief);
        vault.removeWhitelistedRecipients(_ids(thiefId));
        vm.stopPrank();

        address[] memory rs = vault.getWhitelistedRecipients(_ids(thiefId));
        assertEq(rs[0], address(0), "gone now");
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.sendToWhitelistedRecipient(thiefId, address(usdc), 1e6, _none(), _noAmounts());
    }

    /**
     * The timelock cannot be taken away, so neither can the wait: at the shortest it may be, a
     * removal still queues for a day and the entry stays payable until then.
     */
    function test_atTheShortestTimelockARemovalStillWaits() public {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(MIN_RISK_TIMELOCK, UNCHANGED, UNCHANGED));
        vm.warp(T0 + TIMELOCK); // the loosening lands
        vm.prank(owner);
        vault.removeWhitelistedRecipients(_ids(coldId));
        assertEq(vault.getWhitelistedRecipientRemovals(_ids(coldId))[0], T0 + TIMELOCK + MIN_RISK_TIMELOCK);

        _pay(coldId, address(usdc), 1e6);
        assertEq(usdc.balanceOf(cold), 1e6, "still payable while the removal waits");

        vm.warp(T0 + TIMELOCK + MIN_RISK_TIMELOCK);
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.sendToWhitelistedRecipient(coldId, address(usdc), 1e6, _none(), _noAmounts());
    }

    // ── change, as an addition and a removal ──────────────────────────────────

    /**
     * What an in-place edit used to do, from the two operations that each already have a rule.
     * Added and removed in one call, the new destination becomes payable at the moment the old one
     * stops being, so there is never a time with neither.
     */
    function test_aChangeIsAnAdditionAndARemovalInOneCall() public {
        bytes[] memory steps = new bytes[](2);
        steps[0] = abi.encodeCall(BittyV1Vault.addWhitelistedRecipient, (newCold));
        steps[1] = abi.encodeCall(BittyV1Vault.removeWhitelistedRecipients, (_ids(coldId)));
        vm.prank(owner);
        bytes[] memory results = vault.multicall(steps);
        uint256 newId = abi.decode(results[0], (uint256));

        vm.warp(T0 + TIMELOCK - 1);
        _pay(coldId, address(other), 1e18);
        assertEq(other.balanceOf(cold), 1e18, "the old one, until the end");
        vm.prank(owner);
        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        vault.sendToWhitelistedRecipient(newId, address(usdc), 1e6, _none(), _noAmounts());

        vm.warp(T0 + TIMELOCK);
        _pay(newId, address(usdc), 1e6);
        assertEq(usdc.balanceOf(newCold), 1e6, "the new one from the same moment");
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.sendToWhitelistedRecipient(coldId, address(usdc), 1e6, _none(), _noAmounts());
    }

    /**
     * The same pair, interrupted. The lock voids both halves: the new destination never arrives and
     * the old one never leaves.
     */
    function test_aLockMidChangeKeepsTheOldDestination() public {
        bytes[] memory steps = new bytes[](2);
        steps[0] = abi.encodeCall(BittyV1Vault.addWhitelistedRecipient, (thief));
        steps[1] = abi.encodeCall(BittyV1Vault.removeWhitelistedRecipients, (_ids(coldId)));
        vm.prank(owner);
        bytes[] memory results = vault.multicall(steps);
        uint256 thiefId = abi.decode(results[0], (uint256));
        vm.prank(owner);
        vault.emergencyLock();

        vm.warp(T0 + TIMELOCK);
        _pay(coldId, address(usdc), 1e6);
        assertEq(usdc.balanceOf(cold), 1e6, "the old one stayed");
        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        vault.sendToWhitelistedRecipient(thiefId, address(usdc), 1e6, _none(), _noAmounts());
    }

    function test_removingAgainRestartsTheWait() public {
        vm.prank(owner);
        vault.removeWhitelistedRecipients(_ids(coldId));
        vm.warp(T0 + 1 days);
        vm.prank(owner);
        vault.removeWhitelistedRecipients(_ids(coldId));
        assertEq(vault.getWhitelistedRecipientRemovals(_ids(coldId))[0], T0 + 1 days + TIMELOCK);

        vm.warp(T0 + TIMELOCK);
        _pay(coldId, address(usdc), 1e6);
        assertEq(usdc.balanceOf(cold), 1e6);
    }

    /**
     * Re-adding an address whose removal waits makes a second entry on its own window, not a way to
     * call the removal off.
     */
    function test_reAddingAnAddressMakesASeparateEntry() public {
        vm.prank(owner);
        vault.removeWhitelistedRecipients(_ids(coldId));
        vm.warp(T0 + 1 days);
        vm.prank(owner);
        uint256 again = vault.addWhitelistedRecipient(cold);
        assertTrue(again != coldId);

        vm.warp(T0 + TIMELOCK);
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.sendToWhitelistedRecipient(coldId, address(usdc), 1e6, _none(), _noAmounts());
        vm.prank(owner);
        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        vault.sendToWhitelistedRecipient(again, address(usdc), 1e6, _none(), _noAmounts());

        vm.warp(T0 + 1 days + TIMELOCK);
        _pay(again, address(usdc), 1e6);
        assertEq(usdc.balanceOf(cold), 1e6);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _pay(uint256 id, address asset, uint256 amount) internal {
        vm.prank(owner);
        vault.sendToWhitelistedRecipient(id, asset, amount, _none(), _noAmounts());
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = id;
    }

    function _addrs(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _noAmounts() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }
}
