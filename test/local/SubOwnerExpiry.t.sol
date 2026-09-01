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
import {
    IBittyV1SubVault,
    NotParentVault,
    NotSubOwner,
    SubOwnerExpired,
    SubOwnerExpiryInPast
} from "../../src/interfaces/IBittyV1SubVault.sol";
import {GrantTooLong} from "../../src/interfaces/IBittyV1DeFi.sol";
import {SubOwnerDeadlineRequired} from "../../src/interfaces/IBittyV1SubVault.sol";
import {BITTY_GUARD, STABLE_COIN_CATEGORY} from "../../src/logic/Constants.sol";

/**
 * The sub owner's grant expiry — what replaced the asset manager's `expiresAt`.
 *
 * The grant is time-boxed on the SUB, not on a role, and it is enforced in the base the DeFi facet
 * inherits. That placement is the whole point: the facet is delegatecalled, so it runs its own
 * bytecode against the sub's storage and would never reach an override defined on the sub vault.
 *
 * A lapsed grant strands nothing. It stops new positions being taken; both routes home stay open.
 */
contract SubOwnerExpiryTest is Test {
    BittyV1Vault vault;
    BittyV1SubVault subImpl;
    MockGuard guard;
    MockERC20 usdc;
    MockLendingProtocol proto;

    address owner = makeAddr("owner");
    address subOwner = makeAddr("subOwner");
    address weth = makeAddr("weth");

    uint64 constant GRANT = 30 days;
    uint64 constant MAX_GRANT = 10 * 365 days;
    // Every deadline is computed from this rather than from `block.timestamp`. The optimizer treats
    // TIMESTAMP as invariant within a call and caches the first read, so a `block.timestamp` read after
    // a `vm.warp` in the same test still returns the pre-warp value — deadlines built that way land in
    // the past and the test lies about what it proved.
    uint64 constant START = 1_000_000;

    function setUp() public {
        vm.warp(START);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl), abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0))
                ))
        );

        usdc = new MockERC20("USD Coin", "USDC", 6);
        proto = new MockLendingProtocol();
        guard.setAsset(address(usdc), STABLE_COIN_CATEGORY);
        guard.setProtocol(address(proto), LENDING_ID);
        usdc.mint(address(vault), 1_000e6);
    }

    function _expiring(uint64 expiresAt) internal returns (uint256 id, BittyV1SubVault sub) {
        vm.prank(owner);
        (uint256 i, address a) = vault.createSubVault(subOwner, false, expiresAt);
        return (i, BittyV1SubVault(payable(a)));
    }

    /// The sub owner acting on the DeFi surface, through the sub's fallback into the shared facet.
    function _trade(BittyV1SubVault sub) internal {
        BittyV1VaultDeFiFacet(payable(address(sub))).setAutoYieldTrigger(makeAddr("keeper"));
    }

    // ── the default ───────────────────────────────────────────────────────────

    /**
     * There is no open-ended sub grant any more. Ten years is the ceiling, which is what lets renounce
     * leave subs running without a counter tracking which of them could never lapse.
     */
    function test_theLongestGrantIsTheCap() public {
        (, BittyV1SubVault sub) = _expiring(START + MAX_GRANT);
        assertEq(sub.subOwnerExpiresAt(), START + MAX_GRANT, "bounded by the cap, not unbounded");

        vm.warp(START + MAX_GRANT - 1);
        vm.prank(subOwner);
        _trade(sub);
    }

    // ── the gate ──────────────────────────────────────────────────────────────

    function test_theSubOwnerActsUntilTheGrantLapses() public {
        (, BittyV1SubVault sub) = _expiring(START + GRANT);

        vm.warp(START + GRANT - 1);
        vm.prank(subOwner);
        _trade(sub);
    }

    function test_theDeFiSurfaceClosesOnExpiry() public {
        (, BittyV1SubVault sub) = _expiring(START + GRANT);

        vm.warp(START + GRANT);
        vm.prank(subOwner);
        vm.expectRevert(SubOwnerExpired.selector);
        _trade(sub);
    }

    /// Expiry is a lock on new activity, not on the funds: both routes back to the parent survive it.
    function test_valueStillComesHomeAfterExpiry() public {
        (uint256 id, BittyV1SubVault sub) = _expiring(START + GRANT);
        vm.prank(owner);
        vault.fundSubVault(id, _one(address(usdc)), _one(400e6));

        vm.warp(START + GRANT);

        vm.prank(subOwner);
        sub.returnToVault(_one(address(usdc)), _one(100e6));
        assertEq(usdc.balanceOf(address(vault)), 700e6, "sub owner could still hand funds back");

        vm.prank(owner);
        vault.recallFromSubVault(id, _one(address(usdc)), _one(300e6));
        assertEq(usdc.balanceOf(address(sub)), 0, "and the parent could pull the rest");
    }

    // ── the parent's controls ─────────────────────────────────────────────────

    function test_theParentCanExtendALapsedGrant() public {
        (uint256 id, BittyV1SubVault sub) = _expiring(START + GRANT);
        vm.warp(START + GRANT);

        vm.prank(subOwner);
        vm.expectRevert(SubOwnerExpired.selector);
        _trade(sub);

        vm.prank(owner);
        vault.setSubOwnerExpiry(id, START + 2 * GRANT);

        vm.prank(subOwner);
        _trade(sub);
    }

    /// A deadline cannot be lifted, only moved. Revoking a sub owner is assignSubOwner or close.
    function test_aDeadlineCannotBeLifted() public {
        (uint256 id,) = _expiring(START + GRANT);
        vm.prank(owner);
        vm.expectRevert(SubOwnerDeadlineRequired.selector);
        vault.setSubOwnerExpiry(id, 0);
    }

    function test_reassigningSetsTheNewOwnersGrant() public {
        (uint256 id, BittyV1SubVault sub) = _expiring(START + MAX_GRANT);
        address newOwner = makeAddr("newOwner");
        uint64 until = START + GRANT;

        vm.prank(owner);
        vault.assignSubOwner(id, newOwner, until);
        assertEq(sub.owner(), newOwner, "owner moved");
        assertEq(sub.subOwnerExpiresAt(), until, "and came with a deadline");

        (, address[] memory bookOwners, uint64[] memory bookExpiries,,) = vault.getSubVault(_ids(id));
        assertEq(bookOwners[0], newOwner, "registry mirrors the owner");
        assertEq(bookExpiries[0], until, "and the expiry");

        vm.warp(until);
        vm.prank(newOwner);
        vm.expectRevert(SubOwnerExpired.selector);
        _trade(sub);
    }

    // ── refusals ──────────────────────────────────────────────────────────────

    /// A grant that has already lapsed is a dead sub owner, so it is refused rather than stored.
    function test_aGrantThatHasAlreadyLapsedIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(SubOwnerExpiryInPast.selector);
        vault.createSubVault(subOwner, false, START);
    }

    function test_onlyTheParentSetsTheExpiry() public {
        (, BittyV1SubVault sub) = _expiring(START + GRANT);

        vm.prank(subOwner);
        vm.expectRevert(NotParentVault.selector);
        sub.setSubOwnerExpiry(START + GRANT);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        vault.setSubOwnerExpiry(1, START + GRANT);
    }

    // ── wind-down: an expiry stops new risk, never the exit ───────────────────

    /**
     * The bug this replaced: expiry blocked EVERY facet call, so a sub whose value sat in a protocol
     * had no way out at all — nobody could withdraw, so nobody could recall. An expiry has to close
     * the door on new positions without locking the ones already open.
     */
    function test_positionsCanStillBeUnwoundAfterExpiry() public {
        (uint256 id, BittyV1SubVault sub) = _expiring(START + GRANT);
        vm.prank(owner);
        vault.fundSubVault(id, _one(address(usdc)), _one(500e6));
        vm.prank(subOwner);
        BittyV1VaultDeFiFacet(payable(address(sub))).deposit(address(proto), address(usdc), 500e6);

        vm.warp(START + GRANT);

        // New risk is closed.
        vm.prank(subOwner);
        vm.expectRevert(SubOwnerExpired.selector);
        BittyV1VaultDeFiFacet(payable(address(sub))).deposit(address(proto), address(usdc), 1);

        // The exit is not — and it needs no key at all.
        vm.prank(makeAddr("anyone"));
        BittyV1VaultDeFiFacet(payable(address(sub))).withdraw(address(proto), address(usdc), 500e6);
        assertEq(usdc.balanceOf(address(sub)), 500e6, "a stranger unwound the position");
    }

    /// And the way home is permissionless too, so the parent needs no owner to be made whole.
    function test_anyoneCanSendALapsedSubHome() public {
        (uint256 id, BittyV1SubVault sub) = _expiring(START + GRANT);
        vm.prank(owner);
        vault.fundSubVault(id, _one(address(usdc)), _one(400e6));

        vm.prank(makeAddr("anyone"));
        vm.expectRevert(NotSubOwner.selector);
        sub.returnToVault(_one(address(usdc)), _one(400e6));

        vm.warp(START + GRANT);
        vm.prank(makeAddr("anyone"));
        sub.returnToVault(_one(address(usdc)), _one(400e6));
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "value came home without a key");
    }

    /// While the grant is live the sub is nobody else's business.
    function test_aLiveSubIsNotOpenToStrangers() public {
        (uint256 id, BittyV1SubVault sub) = _expiring(START + GRANT);
        vm.prank(owner);
        vault.fundSubVault(id, _one(address(usdc)), _one(100e6));

        vm.prank(makeAddr("anyone"));
        vm.expectRevert();
        BittyV1VaultDeFiFacet(payable(address(sub))).withdraw(address(proto), address(usdc), 1);
    }

    // ── the cap ───────────────────────────────────────────────────────────────

    function test_aGrantBeyondTenYearsIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(GrantTooLong.selector);
        vault.createSubVault(makeAddr("other"), false, START + 10 * 365 days + 1);

        vm.prank(owner);
        vault.createSubVault(makeAddr("other"), false, START + 10 * 365 days);
    }

    // ── the main vault is unaffected ──────────────────────────────────────────

    /// The main vault never writes the sub-vault namespace, so the shared check reads 0 there.
    function test_theMainOwnerNeverExpires() public {
        vm.warp(START + 3650 days);
        vm.prank(owner);
        BittyV1VaultDeFiFacet(payable(address(vault))).setAutoYieldTrigger(makeAddr("keeper"));
        assertEq(vault.subVaultOpenCount(), 0);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _one(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }
}
