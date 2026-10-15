// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_CRYPTO, ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {MockIntentProtocol} from "../helpers/MockIntentProtocol.sol";
import {MockSettlement} from "../helpers/MockSettlement.sol";
import {MockChargeWindow} from "../helpers/MockChargeWindow.sol";
import {INTENT_ID, LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultBase} from "../../src/BittyV1VaultBase.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {AutoYield, IBittyV1Vault, NotTrustedForwarder, VaultLocked} from "../../src/interfaces/IBittyV1Vault.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BITTY_GUARD, BITTY_FORWARDER, PERM_YIELD, PERM_SUPPLY, PERM_INTENT} from "../../src/logic/Constants.sol";

/**
 * The two locks: what they stop, what they leave alone, and which of them can be undone.
 *
 * The vault is built on the assumption that the owner key WILL leak and the owner will still need to
 * use the vault afterwards. So neither lock disables the key — they shrink what any holder of it can
 * reach, down to a box the owner drew before the leak:
 *
 *   - money may still leave, but only to an address whitelisted beforehand, through a scheduled
 *     payment set up beforehand, or as a limit order into a stablecoin that pays this vault;
 *   - value may always come home from a protocol;
 *   - and nothing about the configuration can change — not the destinations, not the delegates, not
 *     the limits, not the code, not the owner — in EITHER direction, because removing an option the
 *     owner still has is as damaging as adding one a thief wants.
 *
 * The permission set is therefore identical in both locks. They differ in exactly two things: an
 * emergency lock can be undone and still lets the relayer charge its fee; a forever lock can do
 * neither, ever.
 */
contract LocksTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 weth;
    MockLendingProtocol sky;
    MockIntentProtocol intent;
    MockSettlement settlement;

    address owner = makeAddr("owner");
    address manager = makeAddr("manager");
    address stranger = makeAddr("stranger");
    address heir = makeAddr("heir");
    address cold = makeAddr("cold"); // whitelisted before any compromise: the way out
    address gasWrapped = makeAddr("gasWrapped");

    uint256 constant UNCHANGED = type(uint256).max;
    uint256 scheduleId;
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
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        sky = new MockLendingProtocol();
        settlement = new MockSettlement();
        intent = new MockIntentProtocol();
        intent.setEndpoints(address(settlement), address(settlement));
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setAsset(address(weth), ASSET_CRYPTO);
        guard.setProtocol(address(sky), LENDING_ID);
        guard.setProtocol(address(intent), INTENT_ID);
        usdc.mint(address(vault), 10_000e6);
        weth.mint(address(vault), 5e18);

        // The charge asks the forwarder whether it is settling for this vault; these tests charge it
        // directly, so the window is held open for the whole file. See {MockChargeWindow}.
        vm.etch(BITTY_FORWARDER, address(new MockChargeWindow()).code);
        MockChargeWindow(BITTY_FORWARDER).setChargingVault(address(vault));

        // A vault in ordinary service before anything goes wrong: a manager, and a cold address
        // money may always be sent to.
        vm.startPrank(owner);
        _f().setAssetManager(manager, uint64(block.timestamp + 365 days), PERM_YIELD | PERM_SUPPLY | PERM_INTENT);
        coldId = vault.addWhitelistedRecipient(cold, address(0));
        vm.stopPrank();
    }

    function _f() internal view returns (BittyV1VaultDeFiFacet) {
        return BittyV1VaultDeFiFacet(payable(address(vault)));
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _one(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _noAmounts() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    /**
     * Every call that must be refused once the vault is locked, as calldata the owner would send.
     */
    function _refusedWhileLocked() internal view returns (bytes[] memory calls) {
        IBittyV1Owner.RiskSettings memory risk = IBittyV1Owner.RiskSettings(1 days, UNCHANGED);

        // Built by appending rather than by index, so removing an entry cannot silently leave a
        // hole — an empty element would reach the fallback and "pass" the refusal it was meant to
        // assert.
        bytes[] memory all = new bytes[](32);
        uint256 n;
        // ownership and code
        all[n++] = abi.encodeCall(BittyV1Vault.transferOwnership, (stranger));
        all[n++] = abi.encodeCall(BittyV1VaultBase.upgrade, (address(0xdead)));
        // risk configuration, both directions
        all[n++] = abi.encodeCall(BittyV1Vault.updateRisk, (risk));
        all[n++] = abi.encodeCall(BittyV1Vault.setStableCoinAsGas, (_one(address(usdc)), 1, 1));
        all[n++] = abi.encodeCall(BittyV1Vault.disableStableCoinAsGas, ());
        all[n++] = abi.encodeCall(BittyV1VaultDeFiFacet.useBittyAllowList, (false));
        all[n++] = abi.encodeCall(BittyV1VaultDeFiFacet.setAssetManager, (stranger, 0, PERM_YIELD));
        all[n++] = abi.encodeCall(BittyV1VaultDeFiFacet.setAutoYieldTrigger, (stranger));
        all[n++] = abi.encodeCall(
            BittyV1VaultDeFiFacet.setAutoYielding, (AutoYield({asset: address(usdc), protocol: address(sky)}))
        );
        all[n++] = abi.encodeCall(BittyV1VaultDeFiFacet.updateAssets, (_one(address(usdc)), _none()));
        all[n++] = abi.encodeCall(BittyV1VaultDeFiFacet.updateProtocols, (_one(address(sky)), _none()));
        // destinations, both directions
        all[n++] = abi.encodeCall(BittyV1Vault.addWhitelistedRecipient, (stranger, address(0)));
        all[n++] = abi.encodeCall(BittyV1Vault.removeWhitelistedRecipients, (_one(coldId)));
        // arbitrary outflow
        all[n++] = abi.encodeCall(BittyV1Vault.send, (stranger, address(usdc), 1e6, _none(), _noAmounts()));
        // new positions
        all[n++] = abi.encodeCall(BittyV1VaultDeFiFacet.deposit, (address(sky), address(usdc), 1e6));
        all[n++] = abi.encodeCall(BittyV1VaultDeFiFacet.autoYield, (address(usdc)));
        // order cancellation
        all[n++] = abi.encodeCall(BittyV1VaultDeFiFacet.cancelIntentOrder, (address(intent), hex"beef"));

        calls = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            calls[i] = all[i];
        }
    }

    function _expectRefused(bytes memory call) internal {
        vm.prank(owner);
        (bool ok, bytes memory ret) = address(vault).call(call);
        assertFalse(ok, "should have been refused while locked");
        assertEq(bytes4(ret), VaultLocked.selector, "refused for the wrong reason");
    }

    // ── engaging and releasing ────────────────────────────────────────────────

    function test_onlyTheOwnerLocks() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vault.emergencyLock();

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, manager));
        vault.foreverLock();
    }

    /// Instant both ways: the owner can try it, see what it does, and carry on.
    function test_theEmergencyLockIsInstantAndReversible() public {
        assertEq(vault.lockLevel(), 0, "unlocked to begin with");

        vm.prank(owner);
        vault.emergencyLock();
        assertEq(vault.lockLevel(), 1, "locked in the same call");

        vm.prank(owner);
        vault.unlock();
        assertEq(vault.lockLevel(), 0, "and released in the same call");
    }

    /// The forever lock needs no preparation and has no way back.
    function test_theForeverLockIsInstantAndFinal() public {
        vm.prank(owner);
        vault.foreverLock();
        assertEq(vault.lockLevel(), 2);

        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        vault.unlock();

        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        vault.emergencyLock();
        assertEq(vault.lockLevel(), 2, "still, and always, final");
    }

    function test_anEmergencyLockCanBeEscalated() public {
        vm.startPrank(owner);
        vault.emergencyLock();
        vault.foreverLock();
        vm.stopPrank();
        assertEq(vault.lockLevel(), 2);
    }

    // ── the sweep: the part an instant release cannot undo ────────────────────

    /**
     * Locking voids what is waiting. A thief's queued grant dies, and because the release is instant
     * they cannot un-cancel it — they must queue it again and wait the whole delay again, which is
     * why pressing the lock once per delay beats a bot.
     */
    function test_lockingVoidsAPendingManagerGrant() public {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(3 days, UNCHANGED));

        vm.prank(owner);
        _f().setAssetManager(stranger, 0, PERM_YIELD);
        (,, address pending,,,) = _f().getAssetManagerSettings();
        assertEq(pending, stranger, "queued behind the timelock");

        vm.prank(owner);
        vault.emergencyLock();
        (,, pending,,,) = _f().getAssetManagerSettings();
        assertEq(pending, address(0), "and the lock voided it");

        // Released again, it does not come back.
        vm.prank(owner);
        vault.unlock();
        vm.warp(block.timestamp + 4 days);
        (address live,,,,,) = _f().getAssetManagerSettings();
        assertEq(live, manager, "the grant that was queued never landed");
    }

    function test_lockingVoidsAPendingRiskLoosening() public {
        vm.startPrank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(3 days, UNCHANGED));
        vault.updateRisk(IBittyV1Owner.RiskSettings(0, UNCHANGED));
        vault.emergencyLock();
        vault.unlock();
        vm.stopPrank();

        vm.warp(block.timestamp + 4 days);
        (uint64 changeTimelock,) = vault.riskSettings();
        assertEq(changeTimelock, 3 days, "the loosening was swept, not merely delayed");
    }

    // ── what is refused ───────────────────────────────────────────────────────

    function test_everyRiskOperationIsRefusedUnderAnEmergencyLock() public {
        vm.prank(owner);
        vault.emergencyLock();
        bytes[] memory calls = _refusedWhileLocked();
        for (uint256 i; i < calls.length; ++i) {
            _expectRefused(calls[i]);
        }
    }

    function test_everyRiskOperationIsRefusedUnderAForeverLock() public {
        vm.prank(owner);
        vault.foreverLock();
        bytes[] memory calls = _refusedWhileLocked();
        for (uint256 i; i < calls.length; ++i) {
            _expectRefused(calls[i]);
        }
    }

    /// The same for a manager acting inside its grant: the bits do not outrank the lock.
    function test_theManagerCannotInvestOrTradeWhileLocked() public {
        vm.prank(owner);
        vault.emergencyLock();

        vm.prank(manager);
        vm.expectRevert(VaultLocked.selector);
        _f().deposit(address(sky), address(usdc), 1e6);
    }

    // ── what is left open ─────────────────────────────────────────────────────

    /// The evacuation route. Unmetered, because the destination was vetted before the compromise.
    function test_aWhitelistedSendStillWorksWhileLocked() public {
        vm.prank(owner);
        vault.emergencyLock();

        vm.prank(owner);
        vault.sendToWhitelistedRecipient(coldId, address(usdc), 1_000e6, _none(), _noAmounts());
        assertEq(usdc.balanceOf(cold), 1_000e6, "out to the address the owner chose in advance");

        vm.prank(owner);
        vault.foreverLock();
        vm.prank(owner);
        vault.sendToWhitelistedRecipient(coldId, address(usdc), 9_000e6, _none(), _noAmounts());
        assertEq(usdc.balanceOf(cold), 10_000e6, "and the forever lock does not close it either");
    }

    /**
     * Value may always come home. Under either lock the owner and the manager can unwind — a
     * withdrawal pays the clone's owner, which is this vault, so it cannot be turned into an exit —
     * and a stranger still cannot, because being locked says nothing about the owner having stopped
     * acting. Where a stranger genuinely needs a position unwound they reach it through
     * {payScheduled}, which pulls from positions to pay what is already owed.
     */
    function test_unwindingStillWorksWhileLocked() public {
        vm.prank(owner);
        _f().deposit(address(sky), address(usdc), 4_000e6);

        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(manager);
        _f().withdraw(address(sky), address(usdc), 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 7_000e6, "the manager brought some back");

        vm.prank(owner);
        vault.foreverLock();
        vm.prank(owner);
        _f().withdraw(address(sky), address(usdc), 2_000e6);
        assertEq(usdc.balanceOf(address(vault)), 9_000e6, "and the owner too, with no way back");

        vm.prank(stranger);
        vm.expectRevert();
        _f().withdraw(address(sky), address(usdc), 1_000e6);
    }

    /// Widening to Bitty's catalog only ever adds reachable assets, so it stays open.
    function test_theBittyAllowListCanStillBeTurnedOnWhileLocked() public {
        vm.startPrank(owner);
        _f().useBittyAllowList(false);
        vault.foreverLock();
        _f().useBittyAllowList(true); // == useBittyAllowList(true)
        vm.stopPrank();
        assertTrue(_f().usingBittyAllowList(), "back to Bitty's list, which is the permissive one");
    }

    /// But narrowing to the vault's own list takes reachable assets away, so that direction is shut.
    function test_theVaultsOwnListCannotBeNarrowedToWhileLocked() public {
        vm.prank(owner);
        vault.foreverLock();
        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        _f().useBittyAllowList(false);
    }

    /**
     * The escape hatch is reachable without a wait.
     *
     * A locked vault sells into stablecoins, and the own allow list decides which stablecoin an
     * order may buy. Returning to Bitty's catalogue is immediate — as it is on an unlocked vault —
     * so an own list that happens to omit the coin a solver wants to pay in is a problem the owner
     * fixes in one call, rather than one that outlives the emergency.
     */
    function test_returningToBittysListIsImmediateWhileLocked() public {
        vm.startPrank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(30 days, UNCHANGED));
        _f().useBittyAllowList(false);
        assertFalse(_f().usingBittyAllowList(), "on the vault's own narrow list");

        vault.emergencyLock();
        _f().useBittyAllowList(true);
        vm.stopPrank();

        assertTrue(_f().usingBittyAllowList(), "back on Bitty's catalogue, with nothing to wait for");
    }

    /// The conversion path needs its allowance, so the approval stays reachable.
    function test_theIntentRelayerCanStillBeApprovedWhileLocked() public {
        vm.startPrank(owner);
        _f().updateProtocols(_one(address(intent)), _none());
        vault.foreverLock();
        _f().approveIntentRelayer(address(intent), address(weth));
        vm.stopPrank();
        assertEq(weth.allowance(address(vault), address(settlement)), type(uint256).max);
    }

    // ── orders: the one trade a locked vault still signs ──────────────────────

    /**
     * The route out of a locked vault that does not need a destination: sell into stablecoins, which
     * is what the whitelisted recipients and the standing payments are denominated in, and let
     * solver competition set the rate. Buying anything else is refused, so a thief cannot use the
     * open trade to rotate the balance into a token of their own.
     */
    function test_onlyStablecoinPurchasesAreAuthorizedWhileLocked() public {
        MockERC20 shiny = new MockERC20("Shiny", "SHINY", 18);
        guard.setAsset(address(shiny), ASSET_CRYPTO);
        vm.prank(owner);
        _f().updateAssets(_one(address(shiny)), _none());

        assertTrue(
            _f().isOffchainOrderAuthorized(owner, address(weth), address(shiny), 1e18), "open: any allowed buy token"
        );

        vm.prank(owner);
        vault.emergencyLock();
        assertFalse(
            _f().isOffchainOrderAuthorized(owner, address(weth), address(shiny), 1e18), "locked: not into that one"
        );
        assertTrue(
            _f().isOffchainOrderAuthorized(owner, address(weth), address(usdc), 1e18), "locked: into stablecoins, yes"
        );
    }

    /// The manager keeps its own independent key, so its intent grant survives a lock as well.
    function test_theManagerMaySillSignStablecoinSalesWhileLocked() public {
        vm.prank(owner);
        vault.foreverLock();
        assertTrue(_f().isOffchainOrderAuthorized(manager, address(weth), address(usdc), 1e18));
    }

    /**
     * Cancellation is the counter-move, so it goes. Otherwise a thief lets the owner sign the sale
     * and cancels it before a solver fills it, indefinitely, for the price of gas.
     */
    function test_cancellationIsRefusedWhileLocked() public {
        assertTrue(_f().isOffchainCancellationAuthorized(owner), "open: the owner may cancel");

        vm.prank(owner);
        vault.emergencyLock();
        assertFalse(_f().isOffchainCancellationAuthorized(owner), "locked: nobody may");
        assertFalse(_f().isOffchainCancellationAuthorized(manager));
    }

    // ── fees: the one permission that differs between the locks ───────────────

    function test_theRelayerStillChargesUnderAnEmergencyLock() public {
        vm.prank(owner);
        vault.emergencyLock();

        vm.prank(BITTY_FORWARDER);
        vault.payRelayerFee(address(usdc), 1e6);
        assertEq(usdc.balanceOf(address(vault)), 9_999e6, "the fee was paid");
    }

    /**
     * Under a forever lock it cannot. Otherwise a thief could burn the vault's gas budget day after
     * day by relaying the operations that are still open — spending nothing of their own, and paying
     * Bitty rather than themselves. The vault stays operable because the forwarder's `execute` is
     * permissionless: the owner signs with the leaked key and ANY funded address submits it.
     */
    function test_theRelayerCannotChargeUnderAForeverLock() public {
        vm.prank(owner);
        vault.foreverLock();

        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(VaultLocked.selector);
        vault.payRelayerFee(address(usdc), 1e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6, "nothing left the vault");
    }

    function test_theReportedGasBudgetIsZeroUnderAForeverLock() public {
        assertGt(vault.gasBudgetRemaining(), 0, "a budget while it is owned normally");
        vm.prank(owner);
        vault.foreverLock();
        assertEq(vault.gasBudgetRemaining(), 0, "and none a relayer could ever collect");
    }
}
