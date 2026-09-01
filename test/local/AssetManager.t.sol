// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {AutoYield, IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {AssetManagerExpiryInPast, AssetManagerNotForSubVault} from "../../src/interfaces/IBittyV1DeFi.sol";
import {BITTY_GUARD, STABLE_COIN_CATEGORY} from "../../src/logic/Constants.sol";

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
    BittyV1SubVault subImpl;
    BittyV1VaultDeFiFacet facet;
    MockGuard guard;
    MockERC20 usdc;
    MockLendingProtocol sky;

    address owner = makeAddr("owner");
    address manager = makeAddr("manager");
    address stranger = makeAddr("stranger");
    address weth = makeAddr("weth");

    uint64 constant START = 1_000_000;
    uint64 constant GRANT = 90 days;
    uint64 constant TIMELOCK = 2 days;
    uint256 constant UNCHANGED = type(uint256).max;

    function _withTimelock() internal {
        vm.prank(owner);
        vault.updatePaymentRisk(IBittyV1Owner.PaymentRisk(UNCHANGED, UNCHANGED, UNCHANGED, TIMELOCK));
    }

    function setUp() public {
        vm.warp(START);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        facet = new BittyV1VaultDeFiFacet();
        subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl), abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0))
                ))
        );

        usdc = new MockERC20("USD Coin", "USDC", 6);
        sky = new MockLendingProtocol();
        guard.setAsset(address(usdc), STABLE_COIN_CATEGORY);
        guard.setProtocol(address(sky), LENDING_ID);
        usdc.mint(address(vault), 1_000e6);
    }

    function _f() internal view returns (BittyV1VaultDeFiFacet) {
        return BittyV1VaultDeFiFacet(payable(address(vault)));
    }

    function _appoint(uint64 expiresAt) internal {
        vm.prank(owner);
        _f().setAssetManager(manager, expiresAt);
    }

    // ── what the manager is for ──────────────────────────────────────────────

    /// The whole point: put idle USDC to work under a delegated key.
    function test_theManagerCanPutIdleFundsToWork() public {
        _appoint(0);
        vm.prank(manager);
        _f().deposit(address(sky), address(usdc), 400e6);
        assertEq(usdc.balanceOf(_f().getClone(address(sky))), 400e6, "the manager deposited");

        vm.prank(manager);
        _f().withdraw(address(sky), address(usdc), 400e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "and pulled it back to the vault");
    }

    /// Intent orders are signed OFF-CHAIN, so without this the manager could not trade at all.
    function test_theManagerMaySignIntentOrders() public {
        _appoint(0);
        assertTrue(
            _f().isOffchainOrderAuthorized(manager, address(usdc), address(usdc), 100e6), "manager may sign a swap"
        );
        assertTrue(_f().isOffchainCancellationAuthorized(manager), "and cancel one");
    }

    function test_theOwnerStillTradesAlongsideTheManager() public {
        _appoint(0);
        vm.prank(owner);
        _f().deposit(address(sky), address(usdc), 100e6);
        assertEq(usdc.balanceOf(_f().getClone(address(sky))), 100e6);
    }

    // ── what the manager must not be able to do ──────────────────────────────

    /// It may work inside the boundary; only the owner moves the boundary.
    function test_theManagerCannotWidenWhatIsReachable() public {
        _appoint(0);
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
        _f().disableTradeUntilTimestamp(START + 1 days);

        vm.prank(manager);
        vm.expectRevert();
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(sky)}));

        vm.prank(manager);
        vm.expectRevert();
        _f().setAutoYieldTrigger(manager);
    }

    /// The payment surface lives on the vault, which the facet cannot reach. No outflow, ever.
    function test_theManagerCannotPayAnyone() public {
        _appoint(0);
        address[] memory none = new address[](0);
        uint256[] memory noAmounts = new uint256[](0);

        vm.prank(manager);
        vm.expectRevert();
        vault.send(manager, address(usdc), 100e6, none, noAmounts);

        vm.prank(manager);
        vm.expectRevert();
        vault.addWhitelistedRecipient(manager, address(usdc));

        assertEq(usdc.balanceOf(manager), 0, "the manager never received anything");
    }

    function test_theManagerCannotAppointOrReplaceItself() public {
        _appoint(0);
        vm.prank(manager);
        vm.expectRevert();
        _f().setAssetManager(stranger, 0);
    }

    function test_aStrangerIsStillAStranger() public {
        _appoint(0);
        vm.prank(stranger);
        vm.expectRevert();
        _f().deposit(address(sky), address(usdc), 100e6);
        assertFalse(_f().isOffchainOrderAuthorized(stranger, address(usdc), address(usdc), 1), "cannot sign either");
    }

    // ── the grant ─────────────────────────────────────────────────────────────

    function test_thereIsNoManagerUntilOneIsNamed() public view {
        (address op, uint64 exp,,) = _f().getAssetManagerSettings();
        assertEq(op, address(0), "the owner alone trades");
        assertEq(exp, 0);
    }

    function test_theGrantLapsesOnTime() public {
        _appoint(START + GRANT);
        (address op, uint64 exp,,) = _f().getAssetManagerSettings();
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
        _appoint(0);
        vm.prank(owner);
        _f().setAssetManager(address(0), 0);

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(sky), address(usdc), 10e6);
    }

    /// Revoking clears the deadline too, so a later re-grant cannot inherit a stale one.
    function test_revokingClearsTheDeadline() public {
        _appoint(START + GRANT);
        vm.prank(owner);
        _f().setAssetManager(address(0), 0);
        (, uint64 exp,,) = _f().getAssetManagerSettings();
        assertEq(exp, 0, "deadline cleared with the grant");
    }

    function test_aGrantThatHasAlreadyLapsedIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(AssetManagerExpiryInPast.selector);
        _f().setAssetManager(manager, START);
    }

    // ── renounce fires every delegate ─────────────────────────────────────────

    /**
     * A renounced vault must have nobody left acting on it. A surviving manager could route the
     * rescue payment's asset into a token that payment cannot pay in — defeating the one mechanism
     * renounce leaves behind, with no owner remaining to revoke them.
     */
    function test_renounceClearsTheManagerAndTheTrigger() public {
        _appoint(0);
        vm.prank(owner);
        _f().setAutoYieldTrigger(makeAddr("keeper"));

        IBittyV1Vault.ScheduledPayment memory sp = IBittyV1Vault.ScheduledPayment({
            recipient: makeAddr("payee"),
            remainingPaymentCount: 5,
            isImmutable: true,
            payWithInsufficientBalance: false,
            trigger: address(0),
            assetAddress: address(usdc),
            amount: 10e6,
            startTimestamp: block.timestamp,
            paymentInterval: 0
        });
        vm.prank(owner);
        uint256 rescue = vault.addScheduledPayment(sp);

        vm.prank(owner);
        vault.renounceVaultOwnership(rescue);
        assertEq(vault.owner(), address(0), "ownerless");

        (address live,, address pending,) = _f().getAssetManagerSettings();
        assertEq(live, address(0), "manager fired");
        assertEq(pending, address(0), "and nothing queued behind them");
        assertEq(_f().autoYieldTrigger(), address(0), "trigger cleared too");

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(sky), address(usdc), 900e6);
    }

    // ── sub vaults have no manager ───────────────────────────────────────────

    /// A sub owner is already the constrained delegate, and a sub cannot send anywhere but its parent,
    /// so there is nothing for an manager to add — and sub-delegation would make the parent's record
    /// of who trades its sub untrue.
    function test_aSubVaultRefusesAManager() public {
        vm.prank(owner);
        (, address account) = vault.createSubVault(makeAddr("subOwner"), false, uint64(block.timestamp) + 365 days);

        vm.prank(makeAddr("subOwner"));
        vm.expectRevert(AssetManagerNotForSubVault.selector);
        BittyV1VaultDeFiFacet(payable(account)).setAssetManager(stranger, 0);
    }

    /// The main vault's manager has no standing inside a sub vault: separate account, separate owner.
    function test_theMainManagerHasNoReachIntoASub() public {
        _appoint(0);
        vm.prank(owner);
        (, address account) = vault.createSubVault(makeAddr("subOwner"), false, uint64(block.timestamp) + 365 days);

        vm.prank(manager);
        vm.expectRevert();
        BittyV1VaultDeFiFacet(payable(account)).deposit(address(sky), address(usdc), 1);
    }

    // ── the ratchet ───────────────────────────────────────────────────────────
    //
    // Appointing and extending wait out the vault's changeTimelock; revoking and shortening do not.
    // Vault ownership is transferable, and a manager survives the handover, so the delay is what stops
    // a stolen owner key planting a permanent trading key that outlives the rescue.

    function test_appointingWaitsOutTheTimelock() public {
        _withTimelock();
        vm.prank(owner);
        _f().setAssetManager(manager, 0);

        (address live,, address pending, uint64 at) = _f().getAssetManagerSettings();
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
        _f().setAssetManager(manager, 0);

        vm.warp(START + TIMELOCK);
        (address live,,,) = _f().getAssetManagerSettings();
        assertEq(live, manager, "promoted without a write");

        vm.prank(manager);
        _f().deposit(address(sky), address(usdc), 10e6);
        assertTrue(_f().isOffchainOrderAuthorized(manager, address(usdc), address(usdc), 1), "and may sign");
    }

    /// The owner's countermeasures never wait: a queued grant can be cancelled before it lands.
    function test_theOwnerCanCancelAQueuedGrant() public {
        _withTimelock();
        vm.prank(owner);
        _f().setAssetManager(manager, 0);

        vm.prank(owner);
        _f().setAssetManager(address(0), 0);

        vm.warp(START + TIMELOCK);
        (address live,, address pending,) = _f().getAssetManagerSettings();
        assertEq(live, address(0), "nothing landed");
        assertEq(pending, address(0), "queue cleared");

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(sky), address(usdc), 10e6);
    }

    function test_revokingIsImmediateEvenWithATimelock() public {
        _appoint(0);
        _withTimelock();

        vm.prank(owner);
        _f().setAssetManager(address(0), 0);

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(sky), address(usdc), 10e6);
    }

    /// Shortening the sitting manager's own grant is a tightening, so it lands at once.
    function test_shorteningIsImmediateButExtendingQueues() public {
        _appoint(START + GRANT);
        _withTimelock();

        vm.prank(owner);
        _f().setAssetManager(manager, START + 1 days);
        (, uint64 exp, address pending,) = _f().getAssetManagerSettings();
        assertEq(exp, START + 1 days, "shortened at once");
        assertEq(pending, address(0), "nothing queued");

        vm.prank(owner);
        _f().setAssetManager(manager, START + GRANT);
        (, uint64 stillShort, address queued,) = _f().getAssetManagerSettings();
        assertEq(stillShort, START + 1 days, "extension has not landed");
        assertEq(queued, manager, "it is queued instead");
    }
}
