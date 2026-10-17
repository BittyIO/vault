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
    WhitelistEntryView,
    WHITELIST_REMOVED,
    WHITELIST_PENDING,
    WHITELIST_PAYABLE,
    WHITELIST_VOIDED,
    WHITELIST_REMOVAL_QUEUED
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * The whitelist read straight from state. It is the vault's way out after a key leaks, so a client
 * (the app, a skill) must be able to see exactly what is on it - and what a thief has queued -
 * without rebuilding it from events. Each status must say what a payout would actually do.
 */
contract WhitelistReadTest is Test {
    BittyV1Vault vault;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address cold = makeAddr("cold");
    address gasWrapped = makeAddr("gasWrapped");

    uint256 constant UNCHANGED = type(uint256).max;
    uint64 constant TIMELOCK = 3 days;
    uint256 constant T0 = 1_000_000;

    function setUp() public {
        vm.warp(T0);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)))
                ))
        );
        usdc = new MockERC20("USD Coin", "USDC", 6);
        MockGuard(BITTY_GUARD).setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 100_000e6);
    }

    function test_anEmptyListReadsAsNothing() public view {
        (uint256 lastId, WhitelistEntryView[] memory entries) = vault.getWhitelist(1, type(uint256).max);
        assertEq(lastId, 0);
        assertEq(entries.length, 0);
    }

    function test_withNoTimelockAnEntryIsPayableAtOnce() public {
        vm.prank(owner);
        uint256 id = vault.addWhitelistedRecipient(cold);

        WhitelistEntryView memory e = _one(id);
        assertEq(e.id, id);
        assertEq(e.recipient, cold);
        assertEq(e.effectiveAt, 0, "payable from the start");
        assertEq(e.removeAt, 0);
        assertEq(e.status, WHITELIST_PAYABLE);
        assertTrue(_canPay(id));
    }

    /**
     * Every status in one list, each held against what a payout to it actually does.
     */
    function test_everyStatusSaysWhatAPayoutWouldDo() public {
        vm.startPrank(owner);
        uint256 payableId = vault.addWhitelistedRecipient(cold);
        uint256 queuedId = vault.addWhitelistedRecipient(makeAddr("queued"));
        vault.updateRisk(IBittyV1Owner.RiskSettings(TIMELOCK, UNCHANGED, UNCHANGED));
        uint256 voidedId = vault.addWhitelistedRecipient(makeAddr("voided"));
        vault.emergencyLock();
        vault.unlock();
        uint256 pendingId = vault.addWhitelistedRecipient(makeAddr("pending"));
        uint256 removedId = vault.addWhitelistedRecipient(makeAddr("removed"));
        vault.removeWhitelistedRecipients(_ids(removedId)); // not payable yet, so it goes at once
        vault.removeWhitelistedRecipients(_ids(queuedId)); // payable, so it waits
        vm.stopPrank();

        (uint256 lastId, WhitelistEntryView[] memory list) = vault.getWhitelist(1, type(uint256).max);
        assertEq(lastId, 5);
        assertEq(list.length, 5);

        assertEq(list[payableId - 1].status, WHITELIST_PAYABLE, "payable");
        assertEq(list[queuedId - 1].status, WHITELIST_REMOVAL_QUEUED, "removal queued");
        assertEq(list[queuedId - 1].removeAt, T0 + TIMELOCK);
        assertEq(list[voidedId - 1].status, WHITELIST_VOIDED, "voided by the lock");
        assertEq(list[voidedId - 1].effectiveAt, T0 + TIMELOCK);
        assertEq(list[pendingId - 1].status, WHITELIST_PENDING, "pending");
        assertEq(list[pendingId - 1].effectiveAt, T0 + TIMELOCK);
        assertEq(list[removedId - 1].status, WHITELIST_REMOVED, "removed");
        assertEq(list[removedId - 1].recipient, address(0));
        _assertStatusesMatchPayouts();

        // After the timelock: the pending entry matured, the queued removal landed, the voided entry
        // stayed voided.
        vm.warp(T0 + TIMELOCK);
        (, list) = vault.getWhitelist(1, type(uint256).max);
        assertEq(list[pendingId - 1].status, WHITELIST_PAYABLE, "matured");
        assertEq(list[queuedId - 1].status, WHITELIST_REMOVED, "removal landed");
        assertEq(list[queuedId - 1].recipient, address(0));
        assertEq(list[voidedId - 1].status, WHITELIST_VOIDED, "voided for good");
        _assertStatusesMatchPayouts();
    }

    /**
     * Locked, the list is the only way out: what reads payable must still pay. The thief's moves -
     * a new destination, and the removal of the owner's - are both voided by the lock.
     */
    function test_underALockPayableStillMeansPayable() public {
        vm.startPrank(owner);
        uint256 coldId = vault.addWhitelistedRecipient(cold);
        vault.updateRisk(IBittyV1Owner.RiskSettings(TIMELOCK, UNCHANGED, UNCHANGED));
        uint256 thiefId = vault.addWhitelistedRecipient(makeAddr("thief"));
        vault.removeWhitelistedRecipients(_ids(coldId));
        assertEq(_one(coldId).status, WHITELIST_REMOVAL_QUEUED);
        vault.emergencyLock();
        vm.stopPrank();

        WhitelistEntryView memory c = _one(coldId);
        assertEq(c.status, WHITELIST_PAYABLE, "the queued removal is voided");
        assertEq(c.removeAt, 0, "and no longer shown as waiting");
        assertEq(_one(thiefId).status, WHITELIST_VOIDED, "the thief's entry, cut off by the lock");
        _assertStatusesMatchPayouts();

        vm.warp(T0 + TIMELOCK * 10);
        assertEq(_one(coldId).status, WHITELIST_PAYABLE, "voided, not postponed");
        _assertStatusesMatchPayouts();
    }

    function test_theRangeIsCutOffAtTheLastId() public {
        _add(5);
        (uint256 lastId, WhitelistEntryView[] memory page) = vault.getWhitelist(2, 2);
        assertEq(lastId, 5);
        assertEq(page.length, 2);
        assertEq(page[0].id, 2);
        assertEq(page[1].id, 3);

        (, page) = vault.getWhitelist(4, 100);
        assertEq(page.length, 2, "cut off at the last id");
        assertEq(page[1].id, 5);

        (, page) = vault.getWhitelist(6, 100);
        assertEq(page.length, 0, "past the end");

        (, page) = vault.getWhitelist(1, 0);
        assertEq(page.length, 0, "count zero");

        (, page) = vault.getWhitelist(0, 1);
        assertEq(page[0].id, 1, "ids start at 1");
    }

    function testFuzz_pagesJoinUpToTheWholeList(uint8 entries, uint8 pageSize) public {
        uint256 n = bound(entries, 0, 40);
        uint256 size = bound(pageSize, 1, 50);
        _add(n);

        (, WhitelistEntryView[] memory all) = vault.getWhitelist(1, type(uint256).max);
        assertEq(all.length, n);
        uint256 seen;
        for (uint256 from = 1; from <= n; from += size) {
            (, WhitelistEntryView[] memory page) = vault.getWhitelist(from, size);
            for (uint256 i; i < page.length; ++i) {
                assertEq(page[i].id, all[seen].id);
                assertEq(page[i].recipient, all[seen].recipient);
                ++seen;
            }
        }
        assertEq(seen, n);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _assertStatusesMatchPayouts() internal {
        (, WhitelistEntryView[] memory list) = vault.getWhitelist(1, type(uint256).max);
        for (uint256 i; i < list.length; ++i) {
            uint8 s = list[i].status;
            bool shouldPay = s == WHITELIST_PAYABLE || s == WHITELIST_REMOVAL_QUEUED;
            assertEq(_canPay(list[i].id), shouldPay, "status disagrees with the payout");
        }
    }

    /**
     * Whether a payout to `id` would go through, asked without keeping its effects.
     */
    function _canPay(uint256 id) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        try vault.sendToWhitelistedRecipient(id, address(usdc), 1e6, new address[](0), new uint256[](0)) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.revertToState(snap);
    }

    function _one(uint256 id) internal view returns (WhitelistEntryView memory) {
        (, WhitelistEntryView[] memory list) = vault.getWhitelist(id, 1);
        return list[0];
    }

    function _add(uint256 n) internal {
        vm.startPrank(owner);
        for (uint256 i; i < n; ++i) {
            vault.addWhitelistedRecipient(address(uint160(0x1000 + i)));
        }
        vm.stopPrank();
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = id;
    }
}
