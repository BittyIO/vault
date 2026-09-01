// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID, STAKING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {AutoYield} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, STABLE_COIN_CATEGORY} from "../../src/logic/Constants.sol";

/// Reaches the DeFi facet through the host's fallback.
interface IFacet {
    function deposit(address protocol, address asset, uint256 amount) external;
    function withdraw(address protocol, address asset, uint256 amount) external;
    function getBalances(address[] calldata protocols, address[] calldata assets)
        external
        view
        returns (uint256[] memory);
    function updateAssets(address[] calldata add, address[] calldata remove) external;
    function updateProtocols(address[] calldata add, address[] calldata remove) external;
    function isAssetAllowed(address asset) external view returns (bool);
    function isProtocolAllowed(address protocol) external view returns (bool);
    function allowlistEnabled() external view returns (bool);
    function enableAllowlist() external;
    function disableAllowlist() external;
    function setAutoYielding(AutoYield calldata route) external;
    function getAutoYieldings(address[] calldata assets) external view returns (address[] memory);
    function autoYield(address asset) external;
    function disableTradeUntilTimestamp(uint256 ts) external;
    function getClone(address protocol) external view returns (address);
}

/**
 * TWO gates decide what a vault may touch, and they answer different questions.
 *
 * The GUARD is Bitty's curated registry — global, shared, and the vault cannot widen it. The local
 * ALLOWLIST is the owner's own narrowing on top. With the allowlist off, anything the guard permits
 * is available; with it on, the owner must also have named it. Neither can override the other in the
 * permissive direction, which is what makes "off" safe: it can only ever fall back to curation.
 */
contract DeFiAllowlistTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockLendingProtocol proto;

    address owner = makeAddr("owner");
    address weth = makeAddr("weth");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        // allowlist OFF at birth for most tests; the ones that need it turn it on.
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

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    // ── the guard is the outer gate ───────────────────────────────────────────

    /// With the allowlist off, anything the guard registers is available with no local setup at all.
    function test_withoutAnAllowlistTheGuardIsTheOnlyGate() public view {
        assertFalse(_f().allowlistEnabled());
        assertTrue(_f().isAssetAllowed(address(usdc)));
        assertTrue(_f().isProtocolAllowed(address(proto)));
    }

    /// And nothing outside the guard is ever available, allowlist or not.
    function test_theGuardCannotBeWidenedLocally() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 18);
        assertFalse(_f().isAssetAllowed(address(rogue)), "unregistered stays out");

        // Even naming it locally does not help — the guard is checked first.
        vm.prank(owner);
        vm.expectRevert();
        _f().updateAssets(_one(address(rogue)), new address[](0));
    }

    /// A protocol the guard has DEPRECATED cannot be entered, even while still registered.
    function test_deprecatedProtocolCannotBeEntered() public {
        guard.setProtocol(address(proto), 0); // MockGuard: category 0 = gone
        vm.prank(owner);
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);
    }

    // ── the local allowlist is the inner gate ─────────────────────────────────

    /**
     * Turning it on narrows immediately — a tightening, so no wait. Anything not yet named becomes
     * unavailable even though the guard still permits it.
     */
    function test_enablingTheAllowlistNarrowsAtOnce() public {
        vm.prank(owner);
        _f().enableAllowlist();
        assertTrue(_f().allowlistEnabled());
        assertFalse(_f().isAssetAllowed(address(usdc)), "guard-registered but not named");

        vm.prank(owner);
        _f().updateAssets(_one(address(usdc)), new address[](0));
        assertTrue(_f().isAssetAllowed(address(usdc)), "named, so allowed again");
    }

    /**
     * Turning it OFF is a loosening, so it waits out the change timelock — the same ratchet the risk
     * controls use. An attacker cannot drop the narrowing and act in the same transaction.
     */
    function test_disablingTheAllowlistWaitsOutTheTimelock() public {
        vm.startPrank(owner);
        vault.updatePaymentRisk(IBittyV1Owner.PaymentRisk(UNCHANGED, UNCHANGED, UNCHANGED, 2 days));
        _f().enableAllowlist();
        _f().disableAllowlist();
        vm.stopPrank();

        assertTrue(_f().allowlistEnabled(), "still on");
        assertFalse(_f().isAssetAllowed(address(usdc)), "and still narrowing");

        vm.warp(block.timestamp + 2 days);
        assertFalse(_f().allowlistEnabled(), "off once the delay has run");
        assertTrue(_f().isAssetAllowed(address(usdc)), "back to the guard alone");
    }

    /// Without a timelock configured it is immediate — the delay is opt-in, like the rest of the ratchet.
    function test_disablingIsImmediateWithNoTimelock() public {
        vm.startPrank(owner);
        _f().enableAllowlist();
        _f().disableAllowlist();
        vm.stopPrank();
        assertFalse(_f().allowlistEnabled());
    }

    /// Re-enabling cancels a pending disable rather than letting it arrive later.
    function test_reEnablingCancelsAPendingDisable() public {
        vm.startPrank(owner);
        vault.updatePaymentRisk(IBittyV1Owner.PaymentRisk(UNCHANGED, UNCHANGED, UNCHANGED, 2 days));
        _f().enableAllowlist();
        _f().disableAllowlist();
        _f().enableAllowlist();
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        assertTrue(_f().allowlistEnabled(), "the abandoned disable never arrives");
    }

    // ── deposit / withdraw ────────────────────────────────────────────────────

    function test_depositAndWithdrawThroughAProtocol() public {
        vm.startPrank(owner);
        _f().deposit(address(proto), address(usdc), 100e6);
        vm.stopPrank();

        address[] memory ps = _one(address(proto));
        address[] memory as_ = _one(address(usdc));
        assertEq(_f().getBalances(ps, as_)[0], 100e6, "position opened");
        assertEq(usdc.balanceOf(address(vault)), 900e6);

        vm.prank(owner);
        _f().withdraw(address(proto), address(usdc), 100e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "and closed");
    }

    /// Entering is gated; EXITING must keep working, or a narrowing would strand the position.
    function test_withdrawStillWorksAfterTheProtocolIsRemovedLocally() public {
        vm.startPrank(owner);
        _f().deposit(address(proto), address(usdc), 100e6);
        _f().enableAllowlist();
        _f().updateProtocols(new address[](0), _one(address(proto)));

        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);

        _f().withdraw(address(proto), address(usdc), 100e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "the position was not stranded");
    }

    function test_onlyOwnerMayDepositOrWithdraw() public {
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);
        vm.expectRevert();
        _f().withdraw(address(proto), address(usdc), 1e6);
        vm.stopPrank();
    }

    // ── auto-yield routes ─────────────────────────────────────────────────────

    function test_ownerSetsAndClearsARoute() public {
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        assertEq(_f().getAutoYieldings(_one(address(usdc)))[0], address(proto), "route set");

        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(0)}));
        assertEq(_f().getAutoYieldings(_one(address(usdc)))[0], address(0), "cleared");
        vm.stopPrank();
    }

    /// The sweep moves the free balance into the configured route.
    function test_autoYieldSweepsIntoTheRoute() public {
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        _f().autoYield(address(usdc));
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 0, "swept");
        assertEq(_f().getBalances(_one(address(proto)), _one(address(usdc)))[0], 1_000e6);
    }

    /// An asset with no route is a no-op, not a revert — a fleet sweep must not fail on one asset.
    function test_autoYieldWithNoRouteIsANoOp() public {
        vm.prank(owner);
        _f().autoYield(address(usdc));
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "untouched, and no revert");
    }

    function test_onlyOwnerMaySetRoutes() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
    }

    // ── trade pause ───────────────────────────────────────────────────────────

    /// Pausing can only ever be pushed LATER, never pulled in — so it cannot be cancelled early.
    function test_tradePauseCanOnlyBeExtended() public {
        vm.startPrank(owner);
        _f().disableTradeUntilTimestamp(block.timestamp + 7 days);
        vm.expectRevert();
        _f().disableTradeUntilTimestamp(block.timestamp + 1 days);
        _f().disableTradeUntilTimestamp(block.timestamp + 14 days);
        vm.stopPrank();
    }

    function test_onlyOwnerMayPauseTrading() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        _f().disableTradeUntilTimestamp(block.timestamp + 1 days);
    }

    // ── clones ────────────────────────────────────────────────────────────────

    /// Each vault gets its OWN clone of a protocol adapter, so positions never share storage.
    function test_eachVaultClonesTheProtocolForItself() public {
        vm.prank(owner);
        _f().deposit(address(proto), address(usdc), 1e6);
        address clone = _f().getClone(address(proto));
        assertTrue(clone != address(0) && clone != address(proto), "a clone, not the template");
    }
}
