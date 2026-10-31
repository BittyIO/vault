// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {AutoYield, IBittyV1Vault, VaultLocked} from "../../src/interfaces/IBittyV1Vault.sol";
import {AssetManagerExpiryInPast} from "../../src/interfaces/IBittyV1DeFi.sol";
import {BITTY_GUARD, MIN_RISK_TIMELOCK, PERM_YIELD, PERM_SUPPLY, PERM_INTENT} from "../../src/logic/Constants.sol";

/*
 * The capabilities these tests appoint a manager for: the jobs a managed vault is actually given —
 * yield, lending and the intent orders it signs — and NOT trading at market, which the owner has to
 * grant by name. See {PERM_YIELD} and the note above it.
 */
uint32 constant MANAGER_PERMS = PERM_YIELD | PERM_SUPPLY | PERM_INTENT;

/**
 * The DeFi manager: the main vault's trading delegate.
 *
 * The role exists so an address — or an agent — can put USDC to work and trade what comes back,
 * without being able to reconfigure the vault or pay anybody. It is the main vault's answer to the
 * question a sub vault answers structurally; a sub vault needs no manager because it cannot send
 * anywhere but its parent.
 *
 * What it must NOT be able to do is the larger half of this file.
 */

contract AssetManagerTest is Test {
    BittyV1Vault vault;
    BittyV1VaultDeFiFacet facet;
    MockGuard guard;
    MockERC20 usdc;
    MockLendingProtocol sky;

    address owner = makeAddr("owner");
    address manager = makeAddr("manager");
    address stranger = makeAddr("stranger");
    address gasWrapped = makeAddr("gasWrapped");

    uint64 constant START = 1_000_000;
    uint64 constant GRANT = 90 days;
    uint64 constant TIMELOCK = 2 days;
    uint256 constant UNCHANGED = type(uint256).max;

    function _withTimelock() internal {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(TIMELOCK, UNCHANGED, UNCHANGED));
    }

    function setUp() public {
        vm.warp(START);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)))
                ))
        );

        usdc = new MockERC20("USD Coin", "USDC", 6);
        sky = new MockLendingProtocol();
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setProtocol(address(sky), LENDING_ID);
        usdc.mint(address(vault), 1_000e6);
    }

    function _f() internal view returns (BittyV1VaultDeFiFacet) {
        return BittyV1VaultDeFiFacet(payable(address(vault)));
    }

    /**
     * Appoint the manager and let the grant land: a new vault's timelock is a day, so even the first
     * appointment waits.
     */
    function _appoint(uint64 expiresAt) internal {
        vm.prank(owner);
        _f().setAssetManager(manager, expiresAt, MANAGER_PERMS);
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
    }

    // ── what the manager is for ──────────────────────────────────────────────

    /// The whole point: put idle USDC to work under a delegated key.
    function test_theManagerCanPutIdleFundsToWork() public {
        _appoint(START + 365 days);
        vm.prank(manager);
        _f().deposit(address(sky), address(usdc), 400e6);
        assertEq(usdc.balanceOf(_f().getClone(address(sky))), 400e6, "the manager deposited");

        vm.prank(manager);
        _f().withdraw(address(sky), address(usdc), 400e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "and pulled it back to the vault");
    }

    /// Intent orders are signed OFF-CHAIN, so without this the manager could not trade at all.
    function test_theManagerMaySignIntentOrders() public {
        _appoint(START + 365 days);
        assertTrue(
            _f().isOffchainOrderAuthorized(manager, address(usdc), address(usdc), 100e6), "manager may sign a swap"
        );
        assertTrue(_f().isOffchainCancellationAuthorized(manager), "and cancel one");
    }

    function test_theOwnerStillTradesAlongsideTheManager() public {
        _appoint(START + 365 days);
        vm.prank(owner);
        _f().deposit(address(sky), address(usdc), 100e6);
        assertEq(usdc.balanceOf(_f().getClone(address(sky))), 100e6);
    }

    // ── what the manager must not be able to do ──────────────────────────────

    /// It may work inside the boundary; only the owner moves the boundary.
    function test_theManagerCannotWidenWhatIsReachable() public {
        _appoint(START + 365 days);
        address[] memory add = new address[](1);
        add[0] = address(usdc);
        address[] memory none = new address[](0);

        vm.prank(manager);
        vm.expectRevert();
        _f().updateAssets(add, none);

        vm.prank(manager);
        vm.expectRevert();
        _f().updateProtocols(add, none);

        vm.prank(manager);
        vm.expectRevert();
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(sky)}));

        vm.prank(manager);
        vm.expectRevert();
        _f().setAutoYieldTrigger(manager);
    }

    /// The payment surface lives on the vault, which the facet cannot reach. No outflow, ever.
    function test_theManagerCannotPayAnyone() public {
        _appoint(START + 365 days);
        address[] memory none = new address[](0);
        uint256[] memory noAmounts = new uint256[](0);

        vm.prank(manager);
        vm.expectRevert();
        vault.send(manager, address(usdc), 100e6, none, noAmounts);

        vm.prank(manager);
        vm.expectRevert();
        vault.addWhitelistedRecipient(manager);

        assertEq(usdc.balanceOf(manager), 0, "the manager never received anything");
    }

    function test_theManagerCannotAppointOrReplaceItself() public {
        _appoint(START + 365 days);
        vm.prank(manager);
        vm.expectRevert();
        _f().setAssetManager(stranger, uint64(block.timestamp + 365 days), MANAGER_PERMS);
    }

    function test_aStrangerIsStillAStranger() public {
        _appoint(START + 365 days);
        vm.prank(stranger);
        vm.expectRevert();
        _f().deposit(address(sky), address(usdc), 100e6);
        assertFalse(_f().isOffchainOrderAuthorized(stranger, address(usdc), address(usdc), 1), "cannot sign either");
    }

    /// Unwinding needs no permission bit, but it does need the grant: a stranger unwinds nothing.
    function test_aStrangerCannotUnwind() public {
        _appoint(START + 365 days);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        _f().withdraw(address(sky), address(usdc), 1);
    }

    /// No manager reads as the zero address, so the zero address must never pass as the manager.
    function test_theZeroAddressIsNeverAnActiveManager() public view {
        assertFalse(_f().isOffchainCancellationAuthorized(address(0)));
    }

    /// An address that is not a protocol has no lineage, so it has no clone either.
    function test_aNonProtocolHasNoClone() public view {
        assertEq(_f().getClone(stranger), address(0), "an EOA");
        assertEq(_f().getClone(address(usdc)), address(0), "a token");
    }

    // ── the grant ─────────────────────────────────────────────────────────────

    function test_thereIsNoManagerUntilOneIsNamed() public view {
        (address op, uint64 exp,,,,) = _f().getAssetManagerSettings();
        assertEq(op, address(0), "the owner alone trades");
        assertEq(exp, 0);
    }

    function test_theGrantLapsesOnTime() public {
        _appoint(START + GRANT);
        (address op, uint64 exp,,,,) = _f().getAssetManagerSettings();
        assertEq(op, manager);
        assertEq(exp, START + GRANT);

        vm.warp(START + GRANT - 1);
        vm.prank(manager);
        _f().deposit(address(sky), address(usdc), 10e6);

        vm.warp(START + GRANT);
        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(sky), address(usdc), 10e6);
        assertFalse(_f().isOffchainOrderAuthorized(manager, address(usdc), address(usdc), 1), "and may no longer sign");
    }

    function test_revokingIsImmediate() public {
        _appoint(START + 365 days);
        vm.prank(owner);
        _f().setAssetManager(address(0), 0, MANAGER_PERMS);

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(sky), address(usdc), 10e6);
    }

    /// Revoking clears the deadline too, so a later re-grant cannot inherit a stale one.
    function test_revokingClearsTheDeadline() public {
        _appoint(START + GRANT);
        vm.prank(owner);
        _f().setAssetManager(address(0), 0, MANAGER_PERMS);
        (, uint64 exp,,,,) = _f().getAssetManagerSettings();
        assertEq(exp, 0, "deadline cleared with the grant");
    }

    function test_aGrantThatHasAlreadyLapsedIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(AssetManagerExpiryInPast.selector);
        _f().setAssetManager(manager, START, MANAGER_PERMS);
    }

    // ── a lock suspends every delegate ────────────────────────────────────────

    /**
     * A renounce used to fire the manager and the keeper outright, because an abandoned vault had
     * nobody left who could revoke them and a surviving manager could have routed the rescue
     * payment's asset into a token that payment could not pay in.
     *
     * A lock does not fire anyone: the manager holds its own key, which is not the one that leaked,
     * and an emergency lock's release should find the help the owner appointed still in place. But
     * while the vault is locked the grant is dormant, so the owner alone acts — including bringing
     * value home, which needs no delegate.
     */
    function test_aForeverLockSuspendsTheManager() public {
        _appoint(START + 365 days);
        vm.prank(owner);
        _f().setAutoYieldTrigger(makeAddr("keeper"));

        vm.prank(manager);
        _f().deposit(address(sky), address(usdc), 900e6);

        // The forever lock needs a destination the vault can still pay out to.
        vm.prank(owner);
        uint256 escape = vault.addWhitelistedRecipient(owner);
        vm.warp(block.timestamp + 31 days);
        vm.prank(owner);
        vault.foreverLock(escape);

        (address live,, address pending,,,) = _f().getAssetManagerSettings();
        assertEq(live, manager, "still appointed: it is not their key that leaked");
        assertEq(pending, address(0));
        assertEq(_f().autoYieldTrigger(), makeAddr("keeper"), "and the keeper is still named");

        bytes memory unauthorized = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", manager);
        vm.prank(manager);
        vm.expectRevert(VaultLocked.selector); // deposits are shut for everyone before anyone is asked
        _f().deposit(address(sky), address(usdc), 100e6);

        vm.prank(manager);
        vm.expectRevert(unauthorized);
        _f().withdraw(address(sky), address(usdc), 900e6);

        vm.prank(owner);
        _f().withdraw(address(sky), address(usdc), 900e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "the owner brings the value back");
    }

    // ── sub vaults have no manager ───────────────────────────────────────────

    // ── the ratchet ───────────────────────────────────────────────────────────
    //
    /**
     * An emergency lock puts the grant to sleep and its release wakes it: nothing was revoked.
     */
    function test_anEmergencyLockSuspendsTheGrantUntilReleased() public {
        _appoint(START + 365 days);
        vm.prank(manager);
        _f().deposit(address(sky), address(usdc), 400e6);
        vm.prank(owner);
        vault.emergencyLock();

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", manager));
        _f().withdraw(address(sky), address(usdc), 400e6);
        assertFalse(_f().isOffchainOrderAuthorized(manager, address(usdc), address(usdc), 1), "nor sign");
        assertTrue(_f().isOffchainOrderAuthorized(owner, address(usdc), address(usdc), 1), "the owner still may");

        vm.prank(owner);
        vault.unlock();
        vm.prank(manager);
        _f().withdraw(address(sky), address(usdc), 400e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    /**
     * A lock freezes the grant like every other setting: it can be neither widened nor revoked, and
     * while locked it is dormant anyway.
     */
    function test_theGrantCannotBeChangedWhileLocked() public {
        _appoint(START + 30 days);
        vm.prank(owner);
        vault.emergencyLock();

        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        _f().setAssetManager(manager, uint64(block.timestamp + 365 days), MANAGER_PERMS);

        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        _f().setAssetManager(manager, uint64(block.timestamp + 1 days), PERM_SUPPLY);

        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        _f().setAssetManager(address(0), 0, 0);
    }

    // Appointing and extending wait out the vault's changeTimelock; revoking and shortening do not.
    // Vault ownership is transferable, and a manager survives the handover, so the delay is what stops
    // a stolen owner key planting a permanent trading key that outlives the rescue.

    function test_appointingWaitsOutTheTimelock() public {
        _withTimelock();
        vm.prank(owner);
        _f().setAssetManager(manager, uint64(block.timestamp + 365 days), MANAGER_PERMS);

        (address live,, address pending, uint64 at,,) = _f().getAssetManagerSettings();
        assertEq(live, address(0), "not live yet");
        assertEq(pending, manager, "queued");
        assertEq(at, START + TIMELOCK, "and dated");

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(sky), address(usdc), 10e6);
    }

    /// The queued grant goes live on time on its own — nobody has to poke the vault to promote it.
    function test_aQueuedGrantGoesLiveOnItsOwn() public {
        _withTimelock();
        vm.prank(owner);
        _f().setAssetManager(manager, uint64(block.timestamp + 365 days), MANAGER_PERMS);

        vm.warp(START + TIMELOCK);
        (address live,,,,,) = _f().getAssetManagerSettings();
        assertEq(live, manager, "promoted without a write");

        vm.prank(manager);
        _f().deposit(address(sky), address(usdc), 10e6);
        assertTrue(_f().isOffchainOrderAuthorized(manager, address(usdc), address(usdc), 1), "and may sign");
    }

    /// The owner's countermeasures never wait: a queued grant can be cancelled before it lands.
    function test_theOwnerCanCancelAQueuedGrant() public {
        _withTimelock();
        vm.prank(owner);
        _f().setAssetManager(manager, uint64(block.timestamp + 365 days), MANAGER_PERMS);

        vm.prank(owner);
        _f().setAssetManager(address(0), 0, MANAGER_PERMS);

        vm.warp(START + TIMELOCK);
        (address live,, address pending,,,) = _f().getAssetManagerSettings();
        assertEq(live, address(0), "nothing landed");
        assertEq(pending, address(0), "queue cleared");

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(sky), address(usdc), 10e6);
    }

    function test_revokingIsImmediateEvenWithATimelock() public {
        _appoint(START + 365 days);
        _withTimelock();

        vm.prank(owner);
        _f().setAssetManager(address(0), 0, MANAGER_PERMS);

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(sky), address(usdc), 10e6);
    }

    /// Shortening the sitting manager's own grant is a tightening, so it lands at once.
    function test_shorteningIsImmediateButExtendingQueues() public {
        _appoint(START + GRANT);
        _withTimelock();

        vm.prank(owner);
        _f().setAssetManager(manager, START + 2 days, MANAGER_PERMS);
        (, uint64 exp, address pending,,,) = _f().getAssetManagerSettings();
        assertEq(exp, START + 2 days, "shortened at once");
        assertEq(pending, address(0), "nothing queued");

        vm.prank(owner);
        _f().setAssetManager(manager, START + GRANT, MANAGER_PERMS);
        (, uint64 stillShort, address queued,,,) = _f().getAssetManagerSettings();
        assertEq(stillShort, START + 2 days, "extension has not landed");
        assertEq(queued, manager, "it is queued instead");
    }
}
