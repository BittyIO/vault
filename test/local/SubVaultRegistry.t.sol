// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {SubVaultNotFound, NotParentVault, SubVaultClosedError} from "../../src/interfaces/IBittyV1SubVault.sol";
import {ImplementationNotRegistered} from "../../src/interfaces/IBittyV1Vault.sol";
import {AddressZero, ArrayLengthMismatch, NoRescueTarget} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, STABLE_COIN_CATEGORY} from "../../src/logic/Constants.sol";

/**
 * The sub-vault registry: the main vault's book of the accounts it has spun out.
 *
 * A sub-vault is a SEPARATE contract with its own owner, so authority is per-account rather than one
 * address with global rights. The registry is what keeps the parent able to recall funds and to
 * refuse renouncing while any sub is still open.
 */
contract SubVaultRegistryTest is Test {
    BittyV1Vault vault;
    BittyV1SubVault subImpl;
    MockGuard guard;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address subOwner = makeAddr("subOwner");
    address weth = makeAddr("weth");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), STABLE_COIN_CATEGORY);
        usdc.mint(address(vault), 1_000e6);
    }

    function _create() internal returns (uint256 id, BittyV1SubVault sub) {
        vm.prank(owner);
        (uint256 i, address a) = vault.createSubVault(subOwner, false, uint64(block.timestamp) + 365 days);
        return (i, BittyV1SubVault(payable(a)));
    }

    // ── lifecycle ─────────────────────────────────────────────────────────────

    function test_createFundRecallClose() public {
        (uint256 id, BittyV1SubVault sub) = _create();
        assertEq(vault.subVaultOpenCount(), 1);
        assertEq(sub.vault(), address(vault), "knows its parent");
        assertEq(sub.owner(), subOwner, "and its own owner");

        vm.prank(owner);
        vault.fundSubVault(id, _one(address(usdc)), _one(600e6));
        assertEq(usdc.balanceOf(address(sub)), 600e6);

        vm.prank(owner);
        vault.recallFromSubVault(id, _one(address(usdc)), _one(600e6));
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "pulled back");

        vm.prank(owner);
        vault.closeSubVault(id);
        assertEq(vault.subVaultOpenCount(), 0);
    }

    /// Each sub gets its own address, derived from the parent and the id.
    function test_subVaultsAreDistinct() public {
        (, BittyV1SubVault a) = _create();
        (, BittyV1SubVault b) = _create();
        assertTrue(address(a) != address(b));
        assertEq(vault.subVaultOpenCount(), 2);
    }

    /**
     * The parent can ALWAYS pull funds back. That is what makes delegating to a sub-owner safe: the
     * authority is real but revocable, without needing the sub-owner's cooperation.
     */
    function test_theParentCanRecallWithoutTheSubOwner() public {
        (uint256 id, BittyV1SubVault sub) = _create();
        vm.prank(owner);
        vault.fundSubVault(id, _one(address(usdc)), _one(500e6));

        vm.prank(owner); // not subOwner
        vault.recallFromSubVault(id, _one(address(usdc)), _one(500e6));
        assertEq(usdc.balanceOf(address(sub)), 0, "recalled over the sub owner's head");
    }

    /// Only the parent may call the sub's privileged entry points — not even its own owner.
    function test_onlyTheParentMayDriveTheSub() public {
        (, BittyV1SubVault sub) = _create();
        vm.startPrank(subOwner);
        vm.expectRevert(NotParentVault.selector);
        sub.recall(_one(address(usdc)), _one(1));
        vm.expectRevert(NotParentVault.selector);
        sub.setSubOwner(makeAddr("x"), 0);
        vm.expectRevert(NotParentVault.selector);
        sub.setGaslessEnabled(true);
        vm.stopPrank();
    }

    // ── ownership of a sub ────────────────────────────────────────────────────

    /// The parent reassigns a sub's owner — the delegation is the parent's to move.
    function test_parentReassignsTheSubOwner() public {
        (uint256 id, BittyV1SubVault sub) = _create();
        address newOwner = makeAddr("newSubOwner");
        vm.prank(owner);
        vault.assignSubOwner(id, newOwner, uint64(block.timestamp) + 365 days);

        assertEq(sub.owner(), newOwner, "the sub contract agrees");
        (, address[] memory bookOwners,,,) = vault.getSubVault(_ids(id));
        assertEq(bookOwners[0], newOwner, "and so does the registry");
    }

    function test_subOwnerCannotBeZero() public {
        (uint256 id,) = _create();
        vm.prank(owner);
        vm.expectRevert(AddressZero.selector);
        vault.assignSubOwner(id, address(0), uint64(block.timestamp) + 365 days);
    }

    function test_cannotCreateWithAZeroOwner() public {
        vm.prank(owner);
        vm.expectRevert(AddressZero.selector);
        vault.createSubVault(address(0), false, uint64(block.timestamp) + 365 days);
    }

    // ── gasless flag ──────────────────────────────────────────────────────────

    /// Relaying for a sub is off until the PARENT turns it on: the parent funds it, so the parent decides.
    function test_parentControlsSubGasless() public {
        (uint256 id, BittyV1SubVault sub) = _create();
        (bool on,,) = sub.gaslessConfig();
        assertFalse(on, "off at birth");

        vm.prank(owner);
        vault.setSubVaultGasless(id, true);
        (on,,) = sub.gaslessConfig();
        assertTrue(on, "the parent switched it on");

        (,,, bool[] memory bookFlags,) = vault.getSubVault(_ids(id));
        assertTrue(bookFlags[0], "and the registry recorded it");
    }

    // ── unknown ids ───────────────────────────────────────────────────────────

    function test_unknownSubIdIsRefusedEverywhere() public {
        vm.startPrank(owner);
        vm.expectRevert(SubVaultNotFound.selector);
        vault.fundSubVault(99, _one(address(usdc)), _one(1e6));
        vm.expectRevert(SubVaultNotFound.selector);
        vault.recallFromSubVault(99, _one(address(usdc)), _one(1e6));
        vm.expectRevert(SubVaultNotFound.selector);
        vault.assignSubOwner(99, makeAddr("x"), uint64(block.timestamp) + 365 days);
        vm.expectRevert(SubVaultNotFound.selector);
        vault.setSubVaultGasless(99, true);
        vm.expectRevert(SubVaultNotFound.selector);
        vault.closeSubVault(99);
        vm.stopPrank();
    }

    /// A closed sub is gone from the book, even though the contract still exists.
    function test_aClosedSubTakesNoMoreFunding() public {
        (uint256 id, BittyV1SubVault sub) = _create();
        vm.prank(owner);
        vault.closeSubVault(id);

        vm.prank(owner);
        vm.expectRevert(SubVaultClosedError.selector);
        vault.fundSubVault(id, _one(address(usdc)), _one(1e6));
        assertTrue(address(sub).code.length > 0, "the contract itself persists");
    }

    /**
     * Closing must never sever recall. The entry used to be deleted, which made every later lookup
     * revert SubVaultNotFound — so closing a sub that still held value put that value beyond the
     * parent for good. The row is marked closed instead, and recall keeps working.
     */
    function test_closingDoesNotStrandWhatIsStillInside() public {
        (uint256 id, BittyV1SubVault sub) = _create();
        vm.prank(owner);
        vault.fundSubVault(id, _one(address(usdc)), _one(500e6));

        vm.prank(owner);
        vault.closeSubVault(id);

        vm.prank(owner);
        vault.recallFromSubVault(id, _one(address(usdc)), _one(500e6));
        assertEq(usdc.balanceOf(address(sub)), 0, "the parent could still pull it back");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "and it landed home");
    }

    /// Closing ends the mandate on the spot, which is what opens the wind-down to anyone.
    function test_closingExpiresTheSubOwner() public {
        (uint256 id, BittyV1SubVault sub) = _create();
        uint64 granted = sub.subOwnerExpiresAt();
        assertGt(granted, block.timestamp, "a live deadline while open");

        vm.prank(owner);
        vault.closeSubVault(id);
        assertEq(sub.subOwnerExpiresAt(), uint64(block.timestamp), "expired on close");

        (,, uint64[] memory bookExpiries,, bool[] memory closedFlags) = vault.getSubVault(_ids(id));
        assertEq(bookExpiries[0], uint64(block.timestamp), "registry agrees");
        assertTrue(closedFlags[0], "and records it closed");
    }

    /**
     * A zero leg is skipped, not refused. Funding takes a list now, and aborting a five-asset transfer
     * because one amount rounded to nothing would be hostile — the same call the sibling
     * {createSubVaultWithDeposits} has always made.
     */
    function test_aZeroFundingLegIsSkipped() public {
        (uint256 id, BittyV1SubVault sub) = _create();
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(usdc);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 500e6;

        vm.prank(owner);
        vault.fundSubVault(id, assets, amounts);
        assertEq(usdc.balanceOf(address(sub)), 500e6, "the funded leg went, the zero one was skipped");
    }

    function test_aRaggedFundingListIsRefused() public {
        (uint256 id,) = _create();
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.fundSubVault(id, _one(address(usdc)), new uint256[](0));
    }

    /// One call into the sub carries the whole list home.
    function test_severalAssetsComeBackInOneRecall() public {
        (uint256 id, BittyV1SubVault sub) = _create();
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        guard.setAsset(address(dai), STABLE_COIN_CATEGORY);
        dai.mint(address(vault), 1_000e18);

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 400e6;
        amounts[1] = 300e18;

        vm.startPrank(owner);
        vault.fundSubVault(id, assets, amounts);
        assertEq(usdc.balanceOf(address(sub)), 400e6);
        assertEq(dai.balanceOf(address(sub)), 300e18);

        vault.recallFromSubVault(id, assets, amounts);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(sub)), 0, "both assets came home");
        assertEq(dai.balanceOf(address(sub)), 0);
    }

    // ── renounce interaction ──────────────────────────────────────────────────

    function test_renounceIgnoresOpenSubs() public {
        _create();
        vm.prank(owner);
        vm.expectRevert(NoRescueTarget.selector); // only the rescue target is still required
        vault.renounceVaultOwnership(1);
    }

    // ── access ────────────────────────────────────────────────────────────────

    function test_onlyOwnerMayManageSubs() public {
        (uint256 id,) = _create();
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert();
        vault.createSubVault(makeAddr("x"), false, uint64(block.timestamp) + 365 days);
        vm.expectRevert();
        vault.fundSubVault(id, _one(address(usdc)), _one(1e6));
        vm.expectRevert();
        vault.recallFromSubVault(id, _one(address(usdc)), _one(1e6));
        vm.expectRevert();
        vault.closeSubVault(id);
        vm.stopPrank();
    }

    /// The sub's OWN owner cannot manage the registry either — that is the parent's book.
    function test_subOwnerCannotManageTheRegistry() public {
        (uint256 id,) = _create();
        vm.prank(subOwner);
        vm.expectRevert();
        vault.recallFromSubVault(id, _one(address(usdc)), _one(1e6));
    }

    // ── upgrades ──────────────────────────────────────────────────────────────

    /// A sub may only be moved to an implementation the guard has blessed.
    function test_subUpgradeRequiresARegisteredImplementation() public {
        (uint256 id,) = _create();
        address rogue = address(new BittyV1SubVault(makeAddr("facet")));
        vm.prank(owner);
        vm.expectRevert(ImplementationNotRegistered.selector);
        vault.upgradeSubVault(id, rogue);

        guard.setImpl(rogue, true);
        vm.prank(owner);
        vault.upgradeSubVault(id, rogue);
    }

    /// And only the parent may move it — a sub cannot upgrade itself.
    function test_subCannotUpgradeItself() public {
        (, BittyV1SubVault sub) = _create();
        address next = address(new BittyV1SubVault(makeAddr("facet")));
        guard.setImpl(next, true);
        vm.prank(subOwner);
        vm.expectRevert(NotParentVault.selector);
        sub.upgradeToAndCall(next, "");
    }

    /**
     * The registry never creates a sub with a missing parent or owner, so these guards sit below the
     * only path that reaches them. Pinned by initializing a raw proxy over the implementation directly,
     * which is what a future account type wiring its own sub would be doing.
     */
    function test_aSubCannotBeBornWithoutAParent() public {
        bytes memory init = abi.encodeCall(
            BittyV1SubVault.initialize, (address(0), makeAddr("subOwner"), false, uint64(block.timestamp + 365 days))
        );
        vm.expectRevert(AddressZero.selector);
        new ERC1967Proxy(address(subImpl), init);
    }

    function test_aSubCannotBeBornWithoutAnOwner() public {
        bytes memory init = abi.encodeCall(
            BittyV1SubVault.initialize, (address(vault), address(0), false, uint64(block.timestamp + 365 days))
        );
        vm.expectRevert(AddressZero.selector);
        new ERC1967Proxy(address(subImpl), init);
    }

    function test_aRawSubProxyInitializesOnlyOnce() public {
        bytes memory init = abi.encodeCall(
            BittyV1SubVault.initialize,
            (address(vault), makeAddr("subOwner"), false, uint64(block.timestamp + 365 days))
        );
        BittyV1SubVault raw = BittyV1SubVault(payable(new ERC1967Proxy(address(subImpl), init)));

        vm.expectRevert();
        raw.initialize(address(vault), makeAddr("other"), false, 0);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _amt(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
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

    // ── a closed sub is closed for good ───────────────────────────────────────
    //
    // Closing expires the sub owner and drops the open count, but the entry stays so its history and
    // any dust remain reachable. What must NOT stay reachable is administration: re-funding it,
    // reassigning it, or extending its owner would all resurrect an account the owner deliberately
    // retired, and `renounceVaultOwnership` counts on closed meaning closed.

    function _closed() internal returns (uint256 id) {
        (id,) = _create();
        vm.prank(owner);
        vault.closeSubVault(id);
    }

    function test_aClosedSubCannotBeReassigned() public {
        uint256 id = _closed();
        vm.prank(owner);
        vm.expectRevert(SubVaultClosedError.selector);
        vault.assignSubOwner(id, makeAddr("newOwner"), uint64(block.timestamp + 30 days));
    }

    function test_aClosedSubsOwnerCannotBeGivenMoreTime() public {
        uint256 id = _closed();
        vm.prank(owner);
        vm.expectRevert(SubVaultClosedError.selector);
        vault.setSubOwnerExpiry(id, uint64(block.timestamp + 30 days));
    }

    function test_aSubCannotBeClosedTwice() public {
        uint256 id = _closed();
        vm.prank(owner);
        vm.expectRevert(SubVaultClosedError.selector);
        vault.closeSubVault(id);
    }

    /// Recall still works: closing must never strand assets already inside.
    function test_aClosedSubCanStillBeEmptied() public {
        (uint256 id, BittyV1SubVault sub) = _create();
        vm.prank(owner);
        vault.fundSubVault(id, _one(address(usdc)), _amt(100e6));

        vm.prank(owner);
        vault.closeSubVault(id);

        vm.prank(owner);
        vault.recallFromSubVault(id, _one(address(usdc)), _amt(100e6));
        assertEq(usdc.balanceOf(address(sub)), 0, "the parent could still pull it out");
    }

    // ── paired arrays ─────────────────────────────────────────────────────────

    function test_fundingWithRaggedArraysIsRefused() public {
        (uint256 id,) = _create();
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.fundSubVault(id, _one(address(usdc)), new uint256[](0));
    }

    function test_recallingWithRaggedArraysIsRefused() public {
        (uint256 id,) = _create();
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.recallFromSubVault(id, _one(address(usdc)), new uint256[](0));
    }

    function test_aZeroAmountLegIsSkippedNotTransferred() public {
        (uint256 id, BittyV1SubVault sub) = _create();
        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        assets[0] = address(usdc);
        assets[1] = address(usdc);
        amounts[0] = 0;
        amounts[1] = 50e6;

        vm.prank(owner);
        vault.fundSubVault(id, assets, amounts);
        assertEq(usdc.balanceOf(address(sub)), 50e6, "only the non-zero leg moved");
    }

    function test_aZeroAmountLegIsSkippedOnTheWayBackToo() public {
        (uint256 id, BittyV1SubVault sub) = _create();
        vm.prank(owner);
        vault.fundSubVault(id, _one(address(usdc)), _amt(50e6));

        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        assets[0] = address(usdc);
        assets[1] = address(usdc);
        amounts[0] = 0;
        amounts[1] = 50e6;

        vm.prank(owner);
        vault.recallFromSubVault(id, assets, amounts);
        assertEq(usdc.balanceOf(address(sub)), 0, "the zero leg was a no-op, the real one returned");
    }
}
