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
import {IBittyV1Vault, VaultLocked} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * The sweep: what a lock does to everything that was still waiting out its timelock.
 *
 * A thief with the owner key spends their waiting period queueing — recipients, scheduled payments,
 * sends — so that the moment the protection window elapses the money has somewhere to go. The lock's
 * job is to kill all of it at once, and the danger is that "all of it" is a number the THIEF chooses.
 * If the lock had to walk the queue to clear it, the thief would queue past the block gas limit and
 * the lock could never be engaged again: the one control the owner has left, disabled by the attacker
 * it exists to stop. Nothing bounds how many entries they can create — the ids are sequential and
 * the only cost is gas — so the sweep cannot be allowed to scale with them at all.
 *
 * So the sweep never deletes and never iterates. It stamps.
 *
 * Each queued entry records the epoch it was created in. A lock bumps the epoch and writes down the
 * time it did so, and an entry is honoured only if its own epoch is current, or if it had ALREADY
 * matured when the epoch it belongs to was closed. Two words per lock, no matter how much is queued.
 * Entries that lose are not erased — they are unreachable, which costs the same to the attacker and
 * nothing to the vault.
 *
 * That gives the three properties these tests pin down:
 *   - a destination that was already live keeps working, because it matured before the lock. It is
 *     the owner's way out and nothing may take it away;
 *   - a destination still inside its window when the lock landed is dead FOREVER — not merely until
 *     the unlock, and not revived by a later lock either, because each epoch's closing time is kept;
 *   - engaging the lock costs the same whether one thing was queued or a thousand.
 *
 * Nothing caps how many additions may be in flight, because nothing needs to. A cap was here for a
 * while, on the reasoning that the owner has to be able to read the pending list before deciding —
 * but it cost 22,000 gas on every addition to enforce something a client gets for nothing by reading
 * the events that created them, and the lock's own cost never depended on it. Measured: two hundred
 * outstanding additions lock for no more than an empty vault does.
 */
contract LockSweepTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address thiefsAddress = makeAddr("thiefsAddress");
    address cold = makeAddr("cold");
    address stranger = makeAddr("stranger");
    address gasWrapped = makeAddr("gasWrapped");

    uint256 constant UNCHANGED = type(uint256).max;
    uint64 constant PROTECTION = 7 days;

    uint256 coldId;

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
        usdc.mint(address(vault), 100_000e6);

        // The vault as it stands before anything goes wrong: one vetted destination, live, and a
        // week of protection on anything added from here on.
        vm.startPrank(owner);
        coldId = vault.addWhitelistedRecipient(cold, address(0));
        vault.updateRisk(IBittyV1Owner.RiskSettings(PROTECTION, UNCHANGED));
        vm.stopPrank();
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _noAmounts() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = id;
    }

    // ── what survives ─────────────────────────────────────────────────────────

    /**
     * The entire point of the design. The owner's cold address was vetted a week before the key
     * leaked, so it is not part of the attack and the lock must not touch it — otherwise engaging the
     * lock would strand the vault with no exit at all.
     */
    function test_aDestinationThatMaturedBeforeTheLockKeepsWorking() public {
        vm.warp(block.timestamp + 30 days);

        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vault.sendToWhitelistedRecipient(coldId, address(usdc), 1_000e6, _none(), _noAmounts());
        assertEq(usdc.balanceOf(cold), 1_000e6, "the mature destination survived the first lock");

        // And it survives every later lock too: the epoch it was closed in remembers that it had
        // already matured, so a second bump cannot sweep it up.
        vm.prank(owner);
        vault.unlock();
        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vault.sendToWhitelistedRecipient(coldId, address(usdc), 1_000e6, _none(), _noAmounts());
        assertEq(usdc.balanceOf(cold), 2_000e6, "and the second lock as well");
    }

    /// A destination queued after a release is ordinary again: it waits its week and then works.
    function test_aDestinationQueuedAfterAReleaseMaturesNormally() public {
        vm.startPrank(owner);
        vault.emergencyLock();
        vault.unlock();
        uint256 id = vault.addWhitelistedRecipient(stranger, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + PROTECTION + 1);
        vm.prank(owner);
        vault.sendToWhitelistedRecipient(id, address(usdc), 1e6, _none(), _noAmounts());
        assertEq(usdc.balanceOf(stranger), 1e6, "the sweep did not poison the new epoch");
    }

    // ── what dies, and stays dead ─────────────────────────────────────────────

    /**
     * The thief's queued destination. Dead at the lock, still dead after the release, and still dead
     * once its original week has elapsed — a release gives the key back its ordinary powers, not its
     * head start.
     */
    function test_aDestinationStillWaitingAtTheLockIsDeadForever() public {
        vm.prank(owner); // the leaked key
        uint256 thiefId = vault.addWhitelistedRecipient(thiefsAddress, address(0));

        vm.prank(owner);
        vault.emergencyLock();

        vm.warp(block.timestamp + PROTECTION + 1);
        vm.prank(owner);
        vault.unlock();

        vm.prank(owner);
        vm.expectRevert();
        vault.sendToWhitelistedRecipient(thiefId, address(usdc), 1e6, _none(), _noAmounts());
        assertEq(usdc.balanceOf(thiefsAddress), 0, "swept, and the wait does not resume");

        // A later lock must not resurrect it by moving the freeze time past its maturity.
        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vault.unlock();
        vm.prank(owner);
        vm.expectRevert();
        vault.sendToWhitelistedRecipient(thiefId, address(usdc), 1e6, _none(), _noAmounts());
    }

    /**
     * THE LIMIT OF THE LOCK, stated plainly.
     *
     * The lock voids what is still inside its protection window and preserves what has matured — it
     * has to, because what has matured includes the owner's own cold address, and a lock that wiped
     * that would leave the vault with no way out at all.
     *
     * The consequence is this: if the owner misses the window ENTIRELY, locking does not undo the
     * thief's destination. It is live, and a whitelisted send is one of the things a locked vault
     * still allows, so the key drains to it. The protection window is the defence; the lock covers
     * only what is still inside one.
     */
    function test_aDestinationThatMaturedBeforeTheLockIsNotUndoneByIt() public {
        vm.prank(owner); // the leaked key
        uint256 thiefId = vault.addWhitelistedRecipient(thiefsAddress, address(0));

        vm.warp(block.timestamp + PROTECTION + 1); // nobody looked
        vm.prank(owner);
        vault.emergencyLock();

        vm.prank(owner);
        vault.sendToWhitelistedRecipient(thiefId, address(usdc), 1_000e6, _none(), _noAmounts());
        assertEq(usdc.balanceOf(thiefsAddress), 1_000e6, "locking came too late for this one");
    }

    /**
     * And the remedy, which is one transaction rather than a race.
     *
     * Removing a destination is refused while locked, on purpose: a thief who could remove one would
     * delete the owner's way out. So the sequence has to be release, remove, re-lock — and the naive
     * reading is that this hands the thief a window in between. It does not, because {multicall}
     * self-delegatecalls each step with the caller's authority intact, so the three run atomically
     * and the vault is never observably open.
     */
    function test_aMaturedDestinationIsRemovedWithoutEverOpeningTheVault() public {
        vm.prank(owner);
        uint256 thiefId = vault.addWhitelistedRecipient(thiefsAddress, address(0));
        vm.warp(block.timestamp + PROTECTION + 1);
        vm.prank(owner);
        vault.emergencyLock();

        bytes[] memory steps = new bytes[](3);
        steps[0] = abi.encodeCall(BittyV1Vault.unlock, ());
        steps[1] = abi.encodeCall(BittyV1Vault.removeWhitelistedRecipients, (_ids(thiefId)));
        steps[2] = abi.encodeCall(BittyV1Vault.emergencyLock, ());
        vm.prank(owner);
        vault.multicall(steps);

        assertEq(vault.lockLevel(), 1, "still locked, and never observably otherwise");
        vm.prank(owner);
        vm.expectRevert();
        vault.sendToWhitelistedRecipient(thiefId, address(usdc), 1e6, _none(), _noAmounts());
        assertEq(usdc.balanceOf(thiefsAddress), 0, "the matured destination is gone");
    }

    // ── the griefing attempt ──────────────────────────────────────────────────

    /**
     * The attack the cap and the stamp exist for. The thief queues as much as the vault will hold
     * and then the owner locks. If engaging the lock cost gas in proportion to what was queued, the
     * thief would simply queue more than a block can clear and the owner would be locked out of
     * locking — the one control they have left, disabled by the thing it defends against.
     */
    function test_lockingCostsTheSameNoMatterHowMuchIsQueued() public {
        uint256 cheap = _gasToLock();

        // The same measurement on a fresh vault, with two hundred additions outstanding. Nothing
        // caps how many a key can queue, and nothing needs to: the lock does not read them.
        setUp();
        vm.startPrank(owner);
        for (uint256 i; i < 200; ++i) {
            vault.addWhitelistedRecipient(address(uint160(0xbad0000 + i)), address(0));
        }
        vm.stopPrank();

        uint256 loaded = _gasToLock();
        assertLt(loaded, cheap + 20_000, "the lock's cost must not follow the size of the queue");
    }

    function _gasToLock() private returns (uint256 used) {
        vm.prank(owner);
        uint256 before = gasleft();
        vault.emergencyLock();
        used = before - gasleft();
    }
}
