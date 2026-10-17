// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {GrantTooLong, AssetManagerExpiryInPast} from "../../src/interfaces/IBittyV1DeFi.sol";
import {BITTY_GUARD, MAX_GRANT_DURATION, PERM_YIELD, PERM_SUPPLY, PERM_INTENT} from "../../src/logic/Constants.sol";

/*
 * The capabilities these tests appoint a manager for: the jobs a managed vault is actually given —
 * yield, lending and the intent orders it signs — and NOT trading at market, which the owner has to
 * grant by name. See {PERM_YIELD} and the note above it.
 */
uint32 constant MANAGER_PERMS = PERM_YIELD | PERM_SUPPLY | PERM_INTENT;

interface IFacet {
    function setAssetManager(address assetManager, uint64 expiresAt, uint32 permissions) external;
    function getAssetManagerSettings()
        external
        view
        returns (
            address manager,
            uint64 expiresAt,
            address pendingManager,
            uint64 pendingAt,
            uint32 permissions,
            uint32 pendingPermissions
        );
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
    address gasWrapped = makeAddr("gasWrapped");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        proto = new MockLendingProtocol();
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setProtocol(address(proto), LENDING_ID);
        usdc.mint(address(vault), 1_000e6);
    }

    function _f() internal view returns (IFacet) {
        return IFacet(address(vault));
    }

    function _timelock(uint64 t) internal {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(t, UNCHANGED, UNCHANGED));
    }

    function _set(address who, uint64 expiresAt) internal {
        vm.prank(owner);
        _f().setAssetManager(who, expiresAt, MANAGER_PERMS);
    }

    // ── granting ──────────────────────────────────────────────────────────────

    function test_withNoTimelockTheGrantIsImmediate() public {
        uint64 expiry = uint64(block.timestamp + 365 days);
        _set(manager, expiry);
        (address m, uint64 e,,,,) = _f().getAssetManagerSettings();
        assertEq(m, manager, "named");
        assertEq(e, expiry, "expiry");
    }

    function test_theManagerMayMoveMoneyBetweenVenues() public {
        _set(manager, uint64(block.timestamp + 365 days));
        vm.prank(manager);
        _f().deposit(address(proto), address(usdc), 100e6);
        assertEq(usdc.balanceOf(_f().getClone(address(proto))), 100e6, "the desk deployed capital");
    }

    function test_theManagerCannotMoveMoneyOut() public {
        _set(manager, uint64(block.timestamp + 365 days));
        vm.prank(manager);
        vm.expectRevert();
        vault.send(stranger, address(usdc), 1e6, new address[](0), new uint256[](0));
    }

    function test_aStrangerIsNotTheManager() public {
        _set(manager, uint64(block.timestamp + 365 days));
        vm.prank(stranger);
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);
    }

    function test_theOwnerStillActsWithAManagerNamed() public {
        _set(manager, uint64(block.timestamp + 365 days));
        vm.prank(owner);
        _f().deposit(address(proto), address(usdc), 100e6);
    }

    /// An unset grant reads as address(0); the check must not treat "nobody" as a match.
    function test_theZeroAddressIsNeverTheManager() public {
        (address m,,,,,) = _f().getAssetManagerSettings();
        assertEq(m, address(0), "no grant at all");

        vm.prank(address(0));
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);
    }

    // ── expiry bounds ─────────────────────────────────────────────────────────

    function test_anExpiryAlreadyPastIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(AssetManagerExpiryInPast.selector);
        _f().setAssetManager(manager, uint64(block.timestamp), MANAGER_PERMS);
    }

    /// There is no "never": every grant expires, so a leaked key stops mattering on its own.
    function test_aZeroExpiryIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(AssetManagerExpiryInPast.selector);
        _f().setAssetManager(manager, 0, MANAGER_PERMS);
    }

    /// Re-naming the live manager with expiry 0 can neither extend the grant nor slip past the
    /// timelock as a "tightening".
    function test_aZeroExpiryCannotReachALiveGrant() public {
        _timelock(1 days);
        uint64 expiry = uint64(block.timestamp + 30 days);
        _set(manager, expiry);
        vm.warp(block.timestamp + 1 days);

        vm.prank(owner);
        vm.expectRevert(AssetManagerExpiryInPast.selector);
        _f().setAssetManager(manager, 0, MANAGER_PERMS);

        (address m, uint64 e,,,,) = _f().getAssetManagerSettings();
        assertEq(m, manager, "still named");
        assertEq(e, expiry, "expiry unchanged");
    }

    /// The expiry only bounds a grant; a revoke takes whatever is passed, 0 included.
    function test_aRevokeNeedsNoExpiry() public {
        _set(manager, uint64(block.timestamp + 365 days));
        _set(address(0), 0);
        (address m, uint64 e,,, uint32 perms,) = _f().getAssetManagerSettings();
        assertEq(m, address(0), "revoked");
        assertEq(e, 0, "no expiry without a manager");
        assertEq(perms, 0, "no permissions without a manager");
        assertFalse(_f().isOffchainCancellationAuthorized(manager), "the old manager is no one");
    }

    function test_anExpiryBeyondTheCeilingIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(GrantTooLong.selector);
        _f().setAssetManager(manager, uint64(block.timestamp + MAX_GRANT_DURATION + 1), MANAGER_PERMS);
    }

    function test_anExpiryExactlyAtTheCeilingIsAccepted() public {
        _set(manager, uint64(block.timestamp + MAX_GRANT_DURATION));
        (address m,,,,,) = _f().getAssetManagerSettings();
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
        _set(manager, uint64(block.timestamp + 365 days));

        (address m,, address pending, uint64 at,,) = _f().getAssetManagerSettings();
        assertEq(m, address(0), "nobody yet");
        assertEq(pending, manager, "queued");
        assertEq(at, uint64(block.timestamp + 2 days), "and dated");

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);

        vm.warp(block.timestamp + 2 days);
        (m,,,,,) = _f().getAssetManagerSettings();
        assertEq(m, manager, "live once the window passes");
        vm.prank(manager);
        _f().deposit(address(proto), address(usdc), 10e6);
    }

    /// The matured grant is folded into the live slot by the next write, not only by reads.
    function test_aMaturedGrantIsSettledByTheNextWrite() public {
        _timelock(2 days);
        _set(manager, uint64(block.timestamp + 365 days));
        vm.warp(block.timestamp + 2 days);

        _set(other, uint64(block.timestamp + 365 days));
        (address m,, address pending,,,) = _f().getAssetManagerSettings();
        assertEq(m, manager, "the matured grant became the live one");
        assertEq(pending, other, "and the new name is what is now queued");
    }

    /// Shortening an existing manager's own expiry is a tightening, so it lands immediately.
    function test_shorteningTheirOwnExpiryIsImmediate() public {
        _set(manager, uint64(block.timestamp + 365 days));
        _timelock(2 days);

        uint64 soon = uint64(block.timestamp + 1 days);
        _set(manager, soon);
        (address m, uint64 e,, uint64 at,,) = _f().getAssetManagerSettings();
        assertEq(m, manager, "same manager");
        assertEq(e, soon, "bounded right away");
        assertEq(at, 0, "nothing queued");
    }

    function test_revokingIsImmediateEvenUnderATimelock() public {
        _set(manager, uint64(block.timestamp + 365 days));
        _timelock(2 days);

        _set(address(0), 0);
        (address m,, address pending,,,) = _f().getAssetManagerSettings();
        assertEq(m, address(0), "gone at once");
        assertEq(pending, address(0), "and nothing queued behind it");

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);
    }

    function test_revokingAlsoDropsAPendingGrant() public {
        _timelock(2 days);
        _set(manager, uint64(block.timestamp + 365 days));
        _set(address(0), 0);

        vm.warp(block.timestamp + 30 days);
        (address m,, address pending,,,) = _f().getAssetManagerSettings();
        assertEq(m, address(0), "the queued grant never landed");
        assertEq(pending, address(0));
    }

    function test_onlyTheOwnerNamesTheManager() public {
        vm.prank(stranger);
        vm.expectRevert();
        _f().setAssetManager(manager, uint64(block.timestamp + 365 days), MANAGER_PERMS);
    }

    // ── unwinding is always open ──────────────────────────────────────────────

    function test_theManagerMayAlwaysUnwind() public {
        _set(manager, uint64(block.timestamp + 365 days));
        vm.prank(owner);
        _f().deposit(address(proto), address(usdc), 100e6);

        vm.prank(manager);
        _f().withdraw(address(proto), address(usdc), 100e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "the desk could exit the position");
    }

    // ── off-chain order authority follows the grant ───────────────────────────

    function test_theManagerMayCancelOrdersOffchain() public {
        _set(manager, uint64(block.timestamp + 365 days));
        assertTrue(_f().isOffchainCancellationAuthorized(manager), "the desk may pull its own orders");
        assertTrue(_f().isOffchainCancellationAuthorized(owner), "so may the owner");
        assertFalse(_f().isOffchainCancellationAuthorized(stranger), "nobody else");
    }
}
