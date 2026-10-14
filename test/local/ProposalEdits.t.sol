// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {AddressZero, ArrayLengthMismatch, WhitelistedRecipientNotFound} from "../../src/interfaces/IBittyV1Vault.sol";
import {MockERC20 as _Unused} from "solmate/test/utils/mocks/MockERC20.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * Editing what is already queued — the half of the proposal lane that is not "add" or "pay".
 *
 * Scheduled payments and whitelisted recipients share one shape: an operator may propose and may edit
 * or withdraw ONLY their own pending proposal, while the owner may edit or cancel anything and their
 * edit clears the pending flag outright. Approval is bound to a content hash, so an operator cannot
 * amend a proposal between the owner reading it and approving it. An immutable schedule, once locked,
 * is outside all of it.
 */
contract ProposalEditsTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address other = makeAddr("otherOperator");
    address payee = makeAddr("payee");
    address gasWrapped = makeAddr("gasWrapped");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 1_000e6);

        vm.startPrank(owner);
        vm.stopPrank();
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _addr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _hashes(bytes32 h) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = h;
    }

    // ── whitelist edits ───────────────────────────────────────────────────────

    function _whitelist(address by) internal returns (uint256 id) {
        vm.prank(by);
        return vault.addWhitelistedRecipient(payee, address(usdc));
    }

    function test_whitelistEditRejectsRaggedArrays() public {
        uint256[] memory ids = new uint256[](2);
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.updateWhitelistedRecipients(ids, _addr(payee), _addr(address(usdc)));
    }

    function test_whitelistEditRejectsTheZeroRecipient() public {
        uint256 id = _whitelist(owner);
        vm.prank(owner);
        vm.expectRevert(AddressZero.selector);
        vault.updateWhitelistedRecipients(_ids(id), _addr(address(0)), _addr(address(usdc)));
    }

    function test_whitelistEditOfAnUnknownIdIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.updateWhitelistedRecipients(_ids(99), _addr(payee), _addr(address(usdc)));
    }

    function test_whitelistEditOfNothingIsHarmless() public {
        vm.prank(owner);
        vault.updateWhitelistedRecipients(new uint256[](0), new address[](0), new address[](0));
    }

    function test_removingAnUnknownWhitelistEntryIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.removeWhitelistedRecipients(_ids(99));
    }

    function test_removingNoWhitelistEntriesIsHarmless() public {
        vm.prank(owner);
        vault.removeWhitelistedRecipients(new uint256[](0));
    }

    // ── a locked vault still pays every standing schedule ────────────────────
}
