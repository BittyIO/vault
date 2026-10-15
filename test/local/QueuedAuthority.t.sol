// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {NextReleaseVault} from "../helpers/NextReleaseVault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultBase} from "../../src/BittyV1VaultBase.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {
    ImplementationNotRegistered,
    OwnershipNotRenounceable,
    PendingChanges,
    VaultLocked
} from "../../src/interfaces/IBittyV1Vault.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";
import {IMPLEMENTATION_VAULT} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";

/**
 * Handing the vault over: one call, then a wait, then it has happened.
 *
 * What the owner needs against a leaked key is TIME — long enough to see a handover they did not ask
 * for and stop it. Not a second signature: a thief supplies a second as easily as a first, which is
 * why the two-step accept this replaced bought nothing while costing every honest handover an extra
 * transaction. So `transferOwnership` records the handover, the vault's timelock runs, and when it
 * expires the new owner IS the owner. Nobody has to come back and confirm.
 *
 * That last part matters beyond convenience. A handover needing a second call from the OLD owner
 * would fail exactly where it is most needed — someone handing the vault on because they are losing
 * access would have to still be there at the end of the wait. Here they do not.
 *
 * The wait is protected by two things rather than a confirmation:
 *   - {BittyV1Vault.cancelOwnershipTransfer}, for an ordinary change of mind; and
 *   - {BittyV1Vault.emergencyLock}, which voids a handover that has not matured and cannot itself be
 *     undone by whoever else holds the key.
 *
 * A vault whose owner set no timelock hands over in the first call. That is their choice — the
 * protection here is time they decided to give themselves — and it is the reason to create a vault
 * with a timelock rather than without one.
 */
contract QueuedAuthorityTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address heir = makeAddr("heir");
    address thief = makeAddr("thief");
    address gasWrapped = makeAddr("gasWrapped");
    address newImpl;

    uint256 constant UNCHANGED = type(uint256).max;
    uint64 constant WAIT = 3 days;
    /**
     * ERC-1967: keccak256("eip1967.proxy.implementation") - 1.
     */
    bytes32 constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        vm.warp(1_000_000);
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
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 10_000e6);

        newImpl = address(new NextReleaseVault(address(facet)));
        guard.setImplFor(newImpl, IMPLEMENTATION_VAULT, true);
    }

    function _pendingOwner() internal view returns (address target, uint64 readyAt) {
        PendingChanges memory changes = vault.pendingChanges();
        return (changes.newOwner, changes.newOwnerReadyAt);
    }

    function _setWait(uint64 wait) internal {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(wait, UNCHANGED));
    }

    // -- handing the vault over -----------------------------------------------

    /// No timelock, no wait. A vault given no window behaves exactly as it did before.
    function test_withoutATimelockAHandoverIsStillOneCall() public {
        vm.prank(owner);
        vault.transferOwnership(heir);
        assertEq(vault.owner(), heir);
    }

    function test_withATimelockTheCallOnlyStartsTheClock() public {
        _setWait(WAIT);

        vm.prank(owner);
        vault.transferOwnership(heir);
        assertEq(vault.owner(), owner, "nothing has moved yet");

        (address target, uint64 readyAt) = _pendingOwner();
        assertEq(target, heir);
        assertEq(readyAt, uint64(block.timestamp) + WAIT);
    }

    /**
     * The heart of it: the handover completes on its own. No second call, no acceptance, nothing the
     * old owner has to still be around for.
     */
    function test_theHandoverCompletesWhenTheTimelockExpires() public {
        _setWait(WAIT);
        vm.prank(owner);
        vault.transferOwnership(heir);

        vm.warp(block.timestamp + WAIT - 1);
        assertEq(vault.owner(), owner, "one second short");

        vm.warp(block.timestamp + 1);
        assertEq(vault.owner(), heir, "and it is theirs, with nobody having lifted a finger");

        (address target,) = _pendingOwner();
        assertEq(target, address(0), "nothing is pending any more: it happened");
    }

    /// Authority follows: the old owner is locked out and the new one is in, by time alone.
    function test_authorityMovesWithTheTimelock() public {
        _setWait(WAIT);
        vm.prank(owner);
        vault.transferOwnership(heir);
        vm.warp(block.timestamp + WAIT);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        vault.updateRisk(IBittyV1Owner.RiskSettings(1 days, UNCHANGED));

        vm.prank(heir);
        vault.updateRisk(IBittyV1Owner.RiskSettings(10 days, UNCHANGED));
        (uint64 timelock,) = vault.riskSettings();
        assertEq(timelock, 10 days, "the new owner is giving the orders");
    }

    /**
     * The DeFi surface has to move with the clock too.
     *
     * It lives on a separate contract reached by delegatecall, so it resolves `owner()` through its
     * own inheritance rather than the vault's. If only the vault honoured a matured handover, the two
     * would disagree for as long as nobody wrote the transfer down: the outgoing owner would keep
     * every DeFi power — deposits, withdrawals, appointing a manager, trading where granted — and the
     * incoming owner would have none. On the handover that matters most, the party losing the vault
     * is exactly the party that must not keep those.
     */
    function test_theDefiSurfaceMovesWithTheClockToo() public {
        _setWait(WAIT);
        vm.prank(owner);
        vault.transferOwnership(heir);
        vm.warp(block.timestamp + WAIT);

        // Nobody has settled, so storage still names the old owner.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        BittyV1VaultDeFiFacet(payable(address(vault))).setAutoYieldTrigger(makeAddr("keeper"));

        vm.prank(heir);
        BittyV1VaultDeFiFacet(payable(address(vault))).setAutoYieldTrigger(makeAddr("keeper"));
        assertEq(
            BittyV1VaultDeFiFacet(payable(address(vault))).autoYieldTrigger(),
            makeAddr("keeper"),
            "the incoming owner is in charge of the DeFi surface as well"
        );
    }

    /**
     * The transfer is in force before anyone writes it down, so writing it down is bookkeeping: it
     * records the new owner in storage and emits the event an indexer is watching for. Anyone may do
     * it, because it cannot change the outcome.
     */
    function test_anyoneMaySettleTheHandoverToRecordIt() public {
        _setWait(WAIT);
        vm.prank(owner);
        vault.transferOwnership(heir);
        vm.warp(block.timestamp + WAIT);

        vm.expectEmit(true, true, false, true, address(vault));
        emit OwnableUpgradeable.OwnershipTransferred(owner, heir);
        vm.prank(makeAddr("anyone"));
        vault.settleOwnershipTransfer();

        assertEq(vault.owner(), heir, "the same answer as before, now written down");
    }

    /// And settling is idempotent — there is nothing to record twice.
    function test_settlingTwiceIsHarmless() public {
        _setWait(WAIT);
        vm.prank(owner);
        vault.transferOwnership(heir);
        vm.warp(block.timestamp + WAIT);

        vault.settleOwnershipTransfer();
        vault.settleOwnershipTransfer();
        assertEq(vault.owner(), heir);
    }

    // -- stopping one ---------------------------------------------------------

    /// For an ordinary change of mind, inside the window.
    function test_aHandoverCanBeCancelledWhileItWaits() public {
        _setWait(WAIT);
        vm.prank(owner);
        vault.transferOwnership(heir);

        vm.prank(owner);
        vault.cancelOwnershipTransfer();
        (address target,) = _pendingOwner();
        assertEq(target, address(0), "called off");

        vm.warp(block.timestamp + WAIT + 1);
        assertEq(vault.owner(), owner, "and the clock no longer runs on anything");
    }

    /**
     * Once the wait is over there is nothing to cancel — the handover is not a proposal any more, it
     * is what happened, and the key that could have called it off is not the owner's any more.
     */
    function test_aMaturedHandoverCannotBeCancelled() public {
        _setWait(WAIT);
        vm.prank(owner);
        vault.transferOwnership(heir);
        vm.warp(block.timestamp + WAIT);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        vault.cancelOwnershipTransfer();
        assertEq(vault.owner(), heir);
    }

    /// Naming someone else replaces the request and starts the wait again from here.
    function test_namingADifferentHeirRestartsTheWait() public {
        _setWait(WAIT);
        vm.prank(owner);
        vault.transferOwnership(heir);

        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vault.transferOwnership(thief);

        (address target, uint64 readyAt) = _pendingOwner();
        assertEq(target, thief);
        assertEq(readyAt, uint64(block.timestamp) + WAIT, "the full wait, not what was left of the old one");

        vm.warp(block.timestamp + 1 days + 1);
        assertEq(vault.owner(), owner, "the first request's deadline means nothing now");
    }

    // -- the lock -------------------------------------------------------------

    /// What the window is FOR: the owner sees a handover they did not ask for, and locks.
    function test_aLockVoidsAHandoverThatHasNotMaturedYet() public {
        _setWait(WAIT);
        vm.prank(owner); // the leaked key
        vault.transferOwnership(thief);

        vm.prank(owner);
        vault.emergencyLock();
        (address target,) = _pendingOwner();
        assertEq(target, address(0), "swept");

        vm.warp(block.timestamp + WAIT + 1);
        assertEq(vault.owner(), owner, "the clock stopped mattering the moment the lock landed");

        // Releasing does not hand the wait back: the thief starts from the beginning.
        vm.prank(owner);
        vault.unlock();
        vm.prank(owner);
        vault.transferOwnership(thief);
        (, uint64 readyAt) = _pendingOwner();
        assertEq(readyAt, uint64(block.timestamp) + WAIT, "queued afresh");
    }

    /**
     * But a lock cannot UNDO one that already matured. By then the handover has happened, and the
     * key that locks the vault is the new owner's — reversing it would be the lock taking the vault
     * off whoever legitimately received it.
     */
    function test_aLockDoesNotUndoAHandoverThatAlreadyCompleted() public {
        _setWait(WAIT);
        vm.prank(owner);
        vault.transferOwnership(heir);
        vm.warp(block.timestamp + WAIT);

        vm.prank(heir);
        vault.emergencyLock();
        assertEq(vault.owner(), heir, "still theirs");
    }

    function test_aHandoverCannotBeStartedWhileLocked() public {
        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        vault.transferOwnership(heir);
    }

    // -- who, and to whom -----------------------------------------------------

    /// Abandonment is gone: a vault with nobody to answer for it is what a forever lock is for.
    function test_theVaultCannotBeAbandoned() public {
        vm.prank(owner);
        vm.expectRevert(OwnershipNotRenounceable.selector);
        vault.transferOwnership(address(0));

        vm.prank(owner);
        vm.expectRevert(OwnershipNotRenounceable.selector);
        vault.renounceOwnership();
    }

    function test_onlyTheOwnerMayStartOrStopAHandover() public {
        _setWait(WAIT);
        vm.prank(thief);
        vm.expectRevert();
        vault.transferOwnership(thief);

        vm.prank(owner);
        vault.transferOwnership(heir);
        vm.prank(thief);
        vm.expectRevert();
        vault.cancelOwnershipTransfer();
    }

    // -- what the owner can see -----------------------------------------------

    /**
     * The read the defence depends on. A thief queues everything they can reach at once; the owner
     * has to see all of it in one call, and the cost of looking must not depend on how much was
     * queued.
     */
    function test_everythingInFlightShowsUpInOneRead() public {
        _setWait(WAIT);

        vm.startPrank(owner); // the leaked key, busy
        vault.transferOwnership(thief);
        BittyV1VaultDeFiFacet(payable(address(vault))).setAssetManager(thief, uint64(block.timestamp + 365 days), 1);
        vault.updateRisk(IBittyV1Owner.RiskSettings(0, UNCHANGED));
        vault.addWhitelistedRecipient(thief, address(0));
        vm.stopPrank();

        PendingChanges memory p = vault.pendingChanges();
        assertEq(p.lockLevel, 0);
        assertEq(p.newOwner, thief, "a handover the owner did not ask for");
        assertEq(p.newOwnerReadyAt, uint64(block.timestamp) + WAIT);
        assertEq(p.newAssetManager, thief, "and a delegate");
        assertEq(p.timelock, 0, "and the wait itself being taken down");
        assertEq(p.timelockAt, uint64(block.timestamp) + WAIT);

        // One call answers all of it, and the lock clears all of it.
        vm.prank(owner);
        vault.emergencyLock();
        p = vault.pendingChanges();
        assertEq(p.lockLevel, 1);
        assertEq(p.newOwner, address(0));
        assertEq(p.newAssetManager, address(0));
        assertEq(p.timelockAt, 0);
    }

    /// A tightening never waits, so it is never something the owner needs warning about.
    function test_aTighteningIsNotReportedAsPending() public {
        _setWait(WAIT);
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(10 days, UNCHANGED));

        PendingChanges memory p = vault.pendingChanges();
        assertEq(p.timelockAt, 0, "it already applied");
        (uint64 timelock,) = vault.riskSettings();
        assertEq(timelock, 10 days);
    }

    // -- replacing the code ---------------------------------------------------

    /**
     * Instant, deliberately, where a handover waits. The wait an upgrade needs already happened
     * somewhere better: an implementation is only a legal target once the guard has blessed it, and
     * the guard timelocks that blessing globally, in public, for every vault at once. Repeating the
     * delay per vault would hold the owner up without removing a single implementation from the set
     * they can reach — the code is what has to prove itself, not the owner.
     */
    function test_anUpgradeIsInstantEvenWithATimelockSet() public {
        _setWait(WAIT);

        vm.prank(owner);
        BittyV1VaultBase(payable(address(vault))).upgrade(newImpl);
        assertEq(vault.owner(), owner, "still ours, on the new code");
        assertEq(address(uint160(uint256(vm.load(address(vault), ERC1967_IMPL_SLOT)))), newImpl, "moved in one call");
    }

    /**
     * The gate that does the work against a stolen key. New code could lift the lock, or rewrite
     * what the lock means, so no holder of the key installs any while the vault is locked.
     */
    function test_anUpgradeIsRefusedWhileLocked() public {
        vm.prank(owner);
        vault.emergencyLock();

        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        BittyV1VaultBase(payable(address(vault))).upgrade(newImpl);

        vm.prank(owner);
        vault.foreverLock();
        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        BittyV1VaultBase(payable(address(vault))).upgrade(newImpl);
    }

    /**
     * Only the owner, and only to something the guard has blessed for vaults.
     */
    function test_anUpgradeStillNeedsTheOwnerAndABlessedTarget() public {
        vm.prank(thief);
        vm.expectRevert();
        BittyV1VaultBase(payable(address(vault))).upgrade(newImpl);

        address unblessed = address(new NextReleaseVault(address(new BittyV1VaultDeFiFacet())));
        vm.prank(owner);
        vm.expectRevert(ImplementationNotRegistered.selector);
        BittyV1VaultBase(payable(address(vault))).upgrade(unblessed);
    }
}
