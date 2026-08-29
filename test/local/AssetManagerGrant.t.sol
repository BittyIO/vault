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
import {
    GrantTooLong,
    AssetManagerExpiryInPast,
    AssetManagerNotForSubVault
} from "../../src/interfaces/IBittyV1DeFi.sol";
import {BITTY_GUARD, STABLE_COIN_CATEGORY, MAX_DURATION} from "../../src/logic/Constants.sol";

interface IFacet {
    function setAssetManager(address assetManager, uint64 expiresAt) external;
    function getAssetManagerSettings()
        external
        view
        returns (address manager, uint64 expiresAt, address pendingManager, uint64 pendingAt);
    function deposit(address protocol, address asset, uint256 amount) external;
    function withdraw(address protocol, address asset, uint256 amount) external;
    function getClone(address protocol) external view returns (address);
    function isOffchainCancellationAuthorized(address signer) external view returns (bool);
}

/**
 * Delegating the trading desk without delegating the vault.
 *
 * An asset manager may move money BETWEEN venues and may always unwind, but can never move money OUT —
 * that stays with the owner. The grant is timelocked in the loosening direction like every other risk
 * change: naming a new manager waits, shortening their expiry does not, so a compromised owner key
 * cannot instantly hand the desk to an attacker while the real owner still has a window to react.
 */
contract AssetManagerGrantTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockLendingProtocol proto;

    address owner = makeAddr("owner");
    address manager = makeAddr("assetManager");
    address other = makeAddr("otherManager");
    address stranger = makeAddr("stranger");
    address weth = makeAddr("weth");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        proto = new MockLendingProtocol();
        guard.setAsset(address(usdc), STABLE_COIN_CATEGORY);
        guard.setProtocol(address(proto), LENDING_ID);
        usdc.mint(address(vault), 1_000e6);
    }

    function _f() internal view returns (IFacet) {
        return IFacet(address(vault));
    }

    function _timelock(uint64 t) internal {
        vm.prank(owner);
        vault.updatePaymentRisk(IBittyV1Owner.PaymentRisk(UNCHANGED, UNCHANGED, UNCHANGED, t));
    }

    function _set(address who, uint64 expiresAt) internal {
        vm.prank(owner);
        _f().setAssetManager(who, expiresAt);
    }

    // ── granting ──────────────────────────────────────────────────────────────

    function test_withNoTimelockTheGrantIsImmediate() public {
        _set(manager, 0);
        (address m, uint64 e,,) = _f().getAssetManagerSettings();
        assertEq(m, manager, "named");
        assertEq(e, 0, "no expiry");
    }

    function test_theManagerMayMoveMoneyBetweenVenues() public {
        _set(manager, 0);
        vm.prank(manager);
        _f().deposit(address(proto), address(usdc), 100e6);
        assertEq(usdc.balanceOf(_f().getClone(address(proto))), 100e6, "the desk deployed capital");
    }

    function test_theManagerCannotMoveMoneyOut() public {
        _set(manager, 0);
        vm.prank(manager);
        vm.expectRevert();
        vault.send(stranger, address(usdc), 1e6, new address[](0), new uint256[](0));
    }

    function test_aStrangerIsNotTheManager() public {
        _set(manager, 0);
        vm.prank(stranger);
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);
    }

    function test_theOwnerStillActsWithAManagerNamed() public {
        _set(manager, 0);
        vm.prank(owner);
        _f().deposit(address(proto), address(usdc), 100e6);
    }

    /// An unset grant reads as address(0); the check must not treat "nobody" as a match.
    function test_theZeroAddressIsNeverTheManager() public {
        (address m,,,) = _f().getAssetManagerSettings();
        assertEq(m, address(0), "no grant at all");

        vm.prank(address(0));
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);
    }

    // ── expiry bounds ─────────────────────────────────────────────────────────

    function test_anExpiryAlreadyPastIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(AssetManagerExpiryInPast.selector);
        _f().setAssetManager(manager, uint64(block.timestamp));
    }

    function test_anExpiryBeyondTheCeilingIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(GrantTooLong.selector);
        _f().setAssetManager(manager, uint64(block.timestamp + MAX_DURATION + 1));
    }

    function test_anExpiryExactlyAtTheCeilingIsAccepted() public {
        _set(manager, uint64(block.timestamp + MAX_DURATION));
        (address m,,,) = _f().getAssetManagerSettings();
        assertEq(m, manager);
    }

    function test_theGrantStopsWorkingWhenItExpires() public {
        uint64 expiry = uint64(block.timestamp + 30 days);
        _set(manager, expiry);

        vm.prank(manager);
        _f().deposit(address(proto), address(usdc), 10e6);

        vm.warp(expiry);
        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 10e6);
    }

    // ── the timelock ratchet ──────────────────────────────────────────────────

    function test_namingANewManagerWaitsOutTheTimelock() public {
        _timelock(2 days);
        _set(manager, 0);

        (address m,, address pending, uint64 at) = _f().getAssetManagerSettings();
        assertEq(m, address(0), "nobody yet");
        assertEq(pending, manager, "queued");
        assertEq(at, uint64(block.timestamp + 2 days), "and dated");

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);

        vm.warp(block.timestamp + 2 days);
        (m,,,) = _f().getAssetManagerSettings();
        assertEq(m, manager, "live once the window passes");
        vm.prank(manager);
        _f().deposit(address(proto), address(usdc), 10e6);
    }

    /// The matured grant is folded into the live slot by the next write, not only by reads.
    function test_aMaturedGrantIsSettledByTheNextWrite() public {
        _timelock(2 days);
        _set(manager, 0);
        vm.warp(block.timestamp + 2 days);

        _set(other, 0);
        (address m,, address pending,) = _f().getAssetManagerSettings();
        assertEq(m, manager, "the matured grant became the live one");
        assertEq(pending, other, "and the new name is what is now queued");
    }

    /// Shortening an existing manager's own expiry is a tightening, so it lands immediately.
    function test_shorteningTheirOwnExpiryIsImmediate() public {
        _set(manager, 0);
        _timelock(2 days);

        uint64 soon = uint64(block.timestamp + 1 days);
        _set(manager, soon);
        (address m, uint64 e,, uint64 at) = _f().getAssetManagerSettings();
        assertEq(m, manager, "same manager");
        assertEq(e, soon, "bounded right away");
        assertEq(at, 0, "nothing queued");
    }

    function test_revokingIsImmediateEvenUnderATimelock() public {
        _set(manager, 0);
        _timelock(2 days);

        _set(address(0), 0);
        (address m,, address pending,) = _f().getAssetManagerSettings();
        assertEq(m, address(0), "gone at once");
        assertEq(pending, address(0), "and nothing queued behind it");

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);
    }

    function test_revokingAlsoDropsAPendingGrant() public {
        _timelock(2 days);
        _set(manager, 0);
        _set(address(0), 0);

        vm.warp(block.timestamp + 30 days);
        (address m,, address pending,) = _f().getAssetManagerSettings();
        assertEq(m, address(0), "the queued grant never landed");
        assertEq(pending, address(0));
    }

    function test_onlyTheOwnerNamesTheManager() public {
        vm.prank(stranger);
        vm.expectRevert();
        _f().setAssetManager(manager, 0);
    }

    // ── unwinding is always open ──────────────────────────────────────────────

    function test_theManagerMayAlwaysUnwind() public {
        _set(manager, 0);
        vm.prank(owner);
        _f().deposit(address(proto), address(usdc), 100e6);

        vm.prank(manager);
        _f().withdraw(address(proto), address(usdc), 100e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "the desk could exit the position");
    }

    // ── off-chain order authority follows the grant ───────────────────────────

    function test_theManagerMayCancelOrdersOffchain() public {
        _set(manager, 0);
        assertTrue(_f().isOffchainCancellationAuthorized(manager), "the desk may pull its own orders");
        assertTrue(_f().isOffchainCancellationAuthorized(owner), "so may the owner");
        assertFalse(_f().isOffchainCancellationAuthorized(stranger), "nobody else");
    }

    // ── a sub vault has no asset manager ──────────────────────────────────────

    function test_aSubVaultCannotNameAnAssetManager() public {
        address subOwner = makeAddr("subOwner");
        vm.prank(owner);
        (, address account) = vault.createSubVault(subOwner, false, uint64(block.timestamp + 30 days));

        vm.prank(subOwner);
        vm.expectRevert(AssetManagerNotForSubVault.selector);
        IFacet(account).setAssetManager(makeAddr("desk"), 0);
    }
}
