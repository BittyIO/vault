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
import {
    PaymentNotStableCoin,
    PaymentExceedsRiskCap,
    ProtectionPeriodNotEnded,
    VaultLocked,
    WhitelistEntryView,
    WHITELIST_PENDING
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, MIN_RISK_TIMELOCK, MAX_SEND_DAILY_ALLOWANCE} from "../../src/logic/Constants.sol";

/**
 * Pay someone and save them, in one call. The commonest thing an owner does with a new address is
 * both at once, and one call is cheaper than the same two in a multicall: the owner and lock checks
 * run once, and the calldata is less than half the size.
 *
 * Each is exactly its two halves: the send is a regular send - stablecoins, under the allowance -
 * and the saved entry waits out the timelock like any other. If either half fails, neither lands.
 */
contract SendAndAddTest is Test {
    BittyV1Vault vault;
    MockERC20 usdc;
    MockERC20 dai;
    MockERC20 other;

    address owner = makeAddr("owner");
    address payee = makeAddr("payee");
    uint256 constant T0 = 1_000_000;

    function setUp() public {
        vm.warp(T0);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        BittyV1Vault.initialize, (owner, makeAddr("gw"), false, address(0), 0, new bytes[](0))
                    )
                ))
        );
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        other = new MockERC20("Other", "OTH", 18);
        MockGuard(BITTY_GUARD).setAsset(address(usdc), ASSET_STABLE_COIN);
        MockGuard(BITTY_GUARD).setAsset(address(dai), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 100_000e6);
        dai.mint(address(vault), 100_000e18);
        other.mint(address(vault), 100e18);
    }

    function test_aSendAndAddPaysNowAndSavesForLater() public {
        vm.prank(owner);
        uint256 id = vault.sendAndAddWhitelistedRecipient(payee, address(usdc), 100e6, _none(), _noAmounts());
        assertEq(usdc.balanceOf(payee), 100e6, "paid now");
        _assertSavedAndWaiting(id);
    }

    function test_aBatchSendAndAddPaysEveryAssetAndSavesForLater() public {
        vm.prank(owner);
        uint256 id = vault.batchSendAndAddWhitelistedRecipient(
            payee, _pair(address(usdc), address(dai)), _pair(100e6, 50e18), new address[][](0), new uint256[][](0)
        );
        assertEq(usdc.balanceOf(payee), 100e6, "every asset");
        assertEq(dai.balanceOf(payee), 50e18);
        _assertSavedAndWaiting(id);
    }

    /// The send is a regular send: a non-stablecoin is refused, and so nothing is saved either.
    function test_aNonStablecoinSendSavesNothing() public {
        vm.prank(owner);
        vm.expectRevert(PaymentNotStableCoin.selector);
        vault.sendAndAddWhitelistedRecipient(payee, address(other), 1e18, _none(), _noAmounts());

        vm.prank(owner);
        vm.expectRevert(PaymentNotStableCoin.selector);
        vault.batchSendAndAddWhitelistedRecipient(
            payee, _pair(address(usdc), address(other)), _pair(1e6, 1e18), new address[][](0), new uint256[][](0)
        );
        _assertNothingSaved();
    }

    /// Over the allowance, the batch total counted, nothing is paid and nothing saved.
    function test_aSendOverTheAllowanceSavesNothing() public {
        uint256 cap = uint256(MAX_SEND_DAILY_ALLOWANCE);
        vm.prank(owner);
        vm.expectRevert(PaymentExceedsRiskCap.selector);
        vault.sendAndAddWhitelistedRecipient(payee, address(usdc), (cap + 1) * 1e6, _none(), _noAmounts());

        vm.prank(owner);
        vm.expectRevert(PaymentExceedsRiskCap.selector);
        vault.batchSendAndAddWhitelistedRecipient(
            payee,
            _pair(address(usdc), address(dai)),
            _pair(cap * 1e6, 1e18), // each within the allowance, over it together
            new address[][](0),
            new uint256[][](0)
        );
        assertEq(usdc.balanceOf(payee), 0);
        _assertNothingSaved();
    }

    function test_bothAreRefusedWhileLocked() public {
        vm.prank(owner);
        vault.emergencyLock();

        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        vault.sendAndAddWhitelistedRecipient(payee, address(usdc), 1e6, _none(), _noAmounts());

        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        vault.batchSendAndAddWhitelistedRecipient(
            payee, _pair(address(usdc), address(dai)), _pair(1e6, 1e18), new address[][](0), new uint256[][](0)
        );
    }

    function test_onlyTheOwnerMayCallEither() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vault.sendAndAddWhitelistedRecipient(stranger, address(usdc), 1e6, _none(), _noAmounts());

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vault.batchSendAndAddWhitelistedRecipient(
            stranger, _pair(address(usdc), address(dai)), _pair(1e6, 1e18), new address[][](0), new uint256[][](0)
        );
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /**
     * Saved, not yet payable: the entry waits out the timelock, then the whitelist path pays it.
     */
    function _assertSavedAndWaiting(uint256 id) internal {
        (uint256 lastId, WhitelistEntryView[] memory list) = vault.getWhitelist(1, type(uint256).max);
        assertEq(lastId, id, "saved");
        assertEq(list[0].recipient, payee);
        assertEq(list[0].status, WHITELIST_PENDING, "waiting out the timelock");
        assertEq(list[0].effectiveAt, T0 + MIN_RISK_TIMELOCK);

        vm.prank(owner);
        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        vault.sendToWhitelistedRecipient(id, address(usdc), 1e6, _none(), _noAmounts());

        vm.warp(T0 + MIN_RISK_TIMELOCK);
        uint256 before = usdc.balanceOf(payee);
        vm.prank(owner);
        vault.sendToWhitelistedRecipient(id, address(usdc), 1e6, _none(), _noAmounts());
        assertEq(usdc.balanceOf(payee), before + 1e6, "payable once the timelock has run");
    }

    function _assertNothingSaved() internal view {
        (uint256 lastId,) = vault.getWhitelist(1, type(uint256).max);
        assertEq(lastId, 0, "nothing saved");
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _noAmounts() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function _pair(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }
}
