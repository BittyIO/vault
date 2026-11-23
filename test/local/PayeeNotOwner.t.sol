// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {
    NewOwnerIsWhitelisted,
    WhitelistedRecipientExists,
    WhitelistedRecipientIsOwner
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BittyStorage} from "../../src/logic/BittyStorage.sol";
import {BITTY_GUARD, MIN_RISK_TIMELOCK} from "../../src/logic/Constants.sol";

/// @dev Where the payee index lives, so a test can put a vault back in its pre-1.1.1 state.
contract PayeeIndexSlots {
    function idsSlot() external view returns (uint256 slot) {
        mapping(address => uint256) storage ids = BittyStorage.vault().whitelistedRecipientIdOf;
        assembly {
            slot := ids.slot
        }
    }
}

/**
 * No payee is an owner. The whitelist is the owner's way out when the key is no longer the
 * owner's alone, so an entry paying that key, or the key a handover is about to give the vault to,
 * would hand the way out to whoever holds it.
 */
contract PayeeNotOwnerTest is Test {
    BittyV1Vault vault;

    address owner = makeAddr("owner");
    address heir = makeAddr("heir");
    address cold = makeAddr("cold");
    address gasWrapped = makeAddr("gasWrapped");

    uint256 constant T0 = 1_000_000;

    function setUp() public {
        vm.warp(T0);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        BittyV1Vault impl = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)))
                ))
        );
    }

    // ------------------------------------------------------------------ the owner is no payee

    function test_theOwnerCannotBeAdded() public {
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientIsOwner.selector);
        vault.addWhitelistedRecipient(owner);
    }

    function test_theNewOwnerOfAQueuedHandoverCannotBeAdded() public {
        vm.startPrank(owner);
        vault.transferOwnership(heir);
        vm.expectRevert(WhitelistedRecipientIsOwner.selector);
        vault.addWhitelistedRecipient(heir);
        vm.stopPrank();
    }

    function test_aCancelledHandoverFreesTheAddress() public {
        vm.startPrank(owner);
        vault.transferOwnership(heir);
        vault.cancelOwnershipTransfer();
        vault.addWhitelistedRecipient(heir);
        vm.stopPrank();
    }

    /// Once the handover is due the new owner owns the vault, even before anything settles it.
    function test_theNewOwnerCannotAddThemselvesOnceTheHandoverIsDue() public {
        vm.prank(owner);
        vault.transferOwnership(heir);
        vm.warp(T0 + MIN_RISK_TIMELOCK);
        assertEq(vault.owner(), heir);
        vm.prank(heir);
        vm.expectRevert(WhitelistedRecipientIsOwner.selector);
        vault.addWhitelistedRecipient(heir);
    }

    // --------------------------------------------------------------- no payee becomes the owner

    function test_aHandoverToAPayeeStillWaitingIsRefused() public {
        vm.startPrank(owner);
        vault.addWhitelistedRecipient(heir);
        vm.expectRevert(NewOwnerIsWhitelisted.selector);
        vault.transferOwnership(heir);
        vm.stopPrank();
    }

    function test_aHandoverToAPayablePayeeIsRefused() public {
        vm.prank(owner);
        vault.addWhitelistedRecipient(heir);
        vm.warp(T0 + MIN_RISK_TIMELOCK);
        vm.prank(owner);
        vm.expectRevert(NewOwnerIsWhitelisted.selector);
        vault.transferOwnership(heir);
    }

    /// A payee not yet payable goes at once, and then the handover is allowed.
    function test_removingAWaitingPayeeAllowsTheHandover() public {
        vm.startPrank(owner);
        uint256 id = vault.addWhitelistedRecipient(heir);
        vault.removeWhitelistedRecipients(_ids(id));
        vault.transferOwnership(heir);
        vm.stopPrank();
        assertEq(vault.pendingChanges().newOwner, heir);
    }

    /// A payable payee's removal waits out the timelock; the handover is refused until it lands.
    function test_aQueuedRemovalCountsUntilItLands() public {
        vm.prank(owner);
        uint256 id = vault.addWhitelistedRecipient(heir);
        vm.warp(T0 + MIN_RISK_TIMELOCK);
        vm.prank(owner);
        vault.removeWhitelistedRecipients(_ids(id));

        vm.prank(owner);
        vm.expectRevert(NewOwnerIsWhitelisted.selector);
        vault.transferOwnership(heir);

        vm.warp(T0 + 2 * MIN_RISK_TIMELOCK);
        vm.prank(owner);
        vault.transferOwnership(heir);
        assertEq(vault.pendingChanges().newOwner, heir);
    }

    // ------------------------------------------------------------------ no address on it twice

    function test_theSameAddressCannotBeAddedTwice() public {
        vm.startPrank(owner);
        vault.addWhitelistedRecipient(cold);
        vm.expectRevert(WhitelistedRecipientExists.selector);
        vault.addWhitelistedRecipient(cold);
        vm.stopPrank();
    }

    function test_aPayableEntryCannotBeAddedAgain() public {
        vm.prank(owner);
        vault.addWhitelistedRecipient(cold);
        vm.warp(T0 + MIN_RISK_TIMELOCK);
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientExists.selector);
        vault.addWhitelistedRecipient(cold);
    }

    function test_aRemovedEntryCanBeAddedAgain() public {
        vm.startPrank(owner);
        uint256 id = vault.addWhitelistedRecipient(cold);
        vault.removeWhitelistedRecipients(_ids(id));
        uint256 again = vault.addWhitelistedRecipient(cold);
        vm.stopPrank();
        assertGt(again, id);
    }

    /// Under a queued removal the entry is still payable, so still there; once it lands, it is not.
    function test_aQueuedRemovalHoldsTheAddressUntilItLands() public {
        vm.prank(owner);
        uint256 id = vault.addWhitelistedRecipient(cold);
        vm.warp(T0 + MIN_RISK_TIMELOCK);
        vm.prank(owner);
        vault.removeWhitelistedRecipients(_ids(id));

        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientExists.selector);
        vault.addWhitelistedRecipient(cold);

        vm.warp(T0 + 2 * MIN_RISK_TIMELOCK);
        vm.prank(owner);
        vault.addWhitelistedRecipient(cold);
    }

    /**
     * A lock voids an entry still waiting: it can never be paid, so it is no payee. The address can
     * be added again after the unlock, and a handover to it is not refused.
     */
    function test_aVoidedEntryNeitherBlocksAnAdditionNorAHandover() public {
        vm.prank(owner);
        vault.addWhitelistedRecipient(heir);
        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vault.unlock();

        vm.startPrank(owner);
        vault.transferOwnership(heir); // the voided entry is no payee
        vault.cancelOwnershipTransfer();
        vault.addWhitelistedRecipient(heir); // and the address can be added again
        vm.stopPrank();
    }

    function test_otherPayeesDoNotStandInTheWay() public {
        vm.startPrank(owner);
        vault.addWhitelistedRecipient(cold);
        vault.transferOwnership(heir);
        vm.stopPrank();
        assertEq(vault.pendingChanges().newOwner, heir);
    }

    /**
     * The check reads only the new owner's own entries, so a list stuffed with other addresses (a
     * thief with the key adding them by the hundred) costs a handover nothing extra.
     */
    function test_aStuffedListDoesNotMakeTheHandoverDearer() public {
        uint256 snap = vm.snapshotState();
        uint256 lean = _handoverGas();
        vm.revertToState(snap);

        vm.startPrank(owner);
        for (uint256 i; i < 300; ++i) {
            vault.addWhitelistedRecipient(address(uint160(0x10000 + i)));
        }
        vm.stopPrank();
        uint256 stuffed = _handoverGas();
        assertLe(stuffed, lean + 5_000, "the handover reads no one else's entries");
    }

    // ------------------------------------------------ entries added before the index existed

    /**
     * Accepted: a vault upgraded to 1.1.1 keeps what it was given before. Its old entries are not
     * indexed, so a handover to one of those addresses goes through; anything added from 1.1.1 on
     * is checked.
     */
    function test_anEntryFromBeforeTheUpgradeIsNotChecked() public {
        vm.prank(owner);
        vault.addWhitelistedRecipient(heir);
        _forgetIndex(heir);

        vm.prank(owner);
        vault.transferOwnership(heir);
        assertEq(vault.pendingChanges().newOwner, heir);
    }

    function test_anEntryAddedAfterTheUpgradeIsChecked() public {
        vm.prank(owner);
        vault.addWhitelistedRecipient(cold);
        _forgetIndex(cold); // an old entry for someone else
        vm.prank(owner);
        vault.addWhitelistedRecipient(heir);

        vm.prank(owner);
        vm.expectRevert(NewOwnerIsWhitelisted.selector);
        vault.transferOwnership(heir);
    }

    // ---------------------------------------------------------------------------------- helpers

    function _handoverGas() private returns (uint256 used) {
        vm.prank(owner);
        uint256 before = gasleft();
        vault.transferOwnership(heir);
        used = before - gasleft();
    }

    /// Make `who`'s entries look as a pre-1.1.1 vault left them: on the list, but not indexed.
    function _forgetIndex(address who) private {
        uint256 idsSlot = new PayeeIndexSlots().idsSlot();
        vm.store(address(vault), keccak256(abi.encode(who, idsSlot)), bytes32(0)); // its ids: none
    }

    function _ids(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}
