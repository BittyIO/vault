// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    AddressZero,
    AmountIsZero,
    ProtectionPeriodNotEnded,
    WhitelistedRecipientNotFound
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, MIN_RISK_TIMELOCK} from "../../src/logic/Constants.sol";

/**
 * Whitelisted recipients: standing payees the owner can pay on demand.
 *
 * One protection: a PROTECTION WINDOW delays a newly added payee, so a compromised key cannot add a
 * destination and drain to it in the same session. The window is what the owner's defence rests on —
 * long enough to notice the addition and reach {BittyV1Vault-emergencyLock}, which voids any entry
 * still inside its window for good.
 *
 * There used to be a second gate: an approval, holding anything a payout operator proposed until the
 * owner confirmed it. Both the gate and the role are gone. A party who could only propose payments
 * put a step in front of the one person who could release them, and every proposal needed approval,
 * review and cancellation paths of its own to go with it.
 */
contract WhitelistTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 other;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address payee = makeAddr("payee");
    address gasWrapped = makeAddr("gasWrapped");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        other = new MockERC20("Other", "OTH", 18);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 1_000e6);
        other.mint(address(vault), 1_000e18);
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    // ── the happy path ────────────────────────────────────────────────────────

    function test_ownerAddsAndPays() public {
        vm.startPrank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee);
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        _pay(id, address(usdc), 10e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(payee), 10e6);
    }

    /**
     * An entry is an address and nothing else: it accepts any asset the vault holds, so that a locked
     * vault, which cannot trade, can still pay out whatever it has.
     */
    function test_anEntryAcceptsAnyAsset() public {
        vm.startPrank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee);
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        _pay(id, address(usdc), 1e6);
        _pay(id, address(other), 1e18);
        vm.stopPrank();
        assertEq(usdc.balanceOf(payee), 1e6);
        assertEq(other.balanceOf(payee), 1e18);
    }

    // ── the protection window ─────────────────────────────────────────────────

    /**
     * A new payee cannot be paid immediately once a window is configured. This is what stops a
     * compromised key adding a destination and draining to it in the same session — the owner has the
     * whole window to notice and remove it.
     */
    function test_aNewPayeeWaitsOutTheProtectionWindow() public {
        vm.startPrank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(3 days, UNCHANGED, UNCHANGED));
        uint256 id = vault.addWhitelistedRecipient(payee);

        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        _pay(id, address(usdc), 1e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        _pay(id, address(usdc), 1e6);
        assertEq(usdc.balanceOf(payee), 1e6, "payable once the window has run");
    }

    // ── access ────────────────────────────────────────────────────────────────

    function test_strangersCannotTouchTheList() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vault.addWhitelistedRecipient(payee);
    }

    // ── bad input ─────────────────────────────────────────────────────────────

    function test_zeroRecipientRejected() public {
        vm.prank(owner);
        vm.expectRevert(AddressZero.selector);
        vault.addWhitelistedRecipient(address(0));
    }

    function test_zeroAmountRejected() public {
        vm.startPrank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee);
        vm.expectRevert(AmountIsZero.selector);
        _pay(id, address(usdc), 0);
        vm.stopPrank();
    }

    function test_unknownIdRejected() public {
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        _pay(999, address(usdc), 1e6);
    }

    function test_removedEntryCannotBePaid() public {
        vm.startPrank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee);
        vault.removeWhitelistedRecipients(_one(id));
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        _pay(id, address(usdc), 1e6);
        vm.stopPrank();
    }

    function test_getWhitelistedRecipientsReadsBack() public {
        vm.prank(owner);
        uint256 id = vault.addWhitelistedRecipient(payee);
        address[] memory rs = vault.getWhitelistedRecipients(_one(id));
        assertEq(rs[0], payee);
    }

    /// Pay with no position-withdrawal legs: the arrays name where the money is pulled FROM, and
    /// these tests are all about the whitelist rules, not the funding source.
    function _pay(uint256 id, address asset, uint256 amount) internal {
        vault.sendToWhitelistedRecipient(id, asset, amount, new address[](0), new uint256[](0));
    }

    function _addrs(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _hashes(bytes32 h) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = h;
    }
}
