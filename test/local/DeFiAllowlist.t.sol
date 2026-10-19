// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID, STAKING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {AutoYield} from "../../src/interfaces/IBittyV1Vault.sol";
import {PaymentNotStableCoin} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

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
    function usingBittyAllowList() external view returns (bool);
    function useBittyAllowList(bool use) external;
    function setAutoYielding(AutoYield calldata route) external;
    function getAutoYieldings(address[] calldata assets) external view returns (address[] memory);
    function autoYield(address asset, uint256 amount) external;
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
    address gasWrapped = makeAddr("gasWrapped");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        // allowlist OFF at birth for most tests; the ones that need it turn it on.
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

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    // ── the guard is the outer gate ───────────────────────────────────────────

    /// With the allowlist off, anything the guard registers is available with no local setup at all.
    function test_withoutAnAllowlistTheGuardIsTheOnlyGate() public view {
        assertTrue(_f().usingBittyAllowList());
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
        _f().useBittyAllowList(false);
        assertFalse(_f().usingBittyAllowList());
        assertFalse(_f().isAssetAllowed(address(usdc)), "guard-registered but not named");

        vm.prank(owner);
        _f().updateAssets(_one(address(usdc)), new address[](0));
        assertTrue(_f().isAssetAllowed(address(usdc)), "named, so allowed again");
    }

    /**
     * Turning it off is immediate too, even with a timelock configured.
     *
     * It IS a loosening — more assets become reachable — and loosenings normally wait. This one is
     * the exception, on the grounds that the set it widens to is Bitty's vetted catalogue rather
     * than anything the caller chooses, and that what a thief gains by switching is market trading,
     * which the owner key can already abuse on every asset the vault has listed. Against that, a
     * delay meant an owner could not TRY the catalogue without committing to it for as long as the
     * timelock, which pushed people onto a hand-made list that serves them worse.
     */
    function test_returningToTheCatalogueIsImmediate() public {
        vm.startPrank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(30 days, UNCHANGED, UNCHANGED));
        _f().useBittyAllowList(false);
        assertFalse(_f().isAssetAllowed(address(usdc)), "narrowed, and the asset is not listed");

        _f().useBittyAllowList(true);
        vm.stopPrank();

        assertTrue(_f().usingBittyAllowList(), "no wait");
        assertTrue(_f().isAssetAllowed(address(usdc)), "and the guard is the only gate again");
    }

    /// Both directions settle in the call that asks for them, so nothing arrives later.
    function test_neitherDirectionLeavesAnythingPending() public {
        vm.startPrank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(2 days, UNCHANGED, UNCHANGED));
        _f().useBittyAllowList(true);
        _f().useBittyAllowList(false);
        vm.stopPrank();

        assertFalse(_f().usingBittyAllowList(), "narrowed, as last asked");
        vm.warp(block.timestamp + 30 days);
        assertFalse(_f().usingBittyAllowList(), "and a month later it has not drifted");
    }

    // ── the own list narrows what a capped send may pay in ────────────────────

    /**
     * Once a daily allowance applies, only stable coins may be sent — the cap is a dollar figure and
     * cannot bound a token it has no way to price. "Stable coin" means registered with the guard AND
     * reachable, so narrowing to the vault's own list takes a coin out of the spendable set until the
     * owner lists it.
     */
    function test_underACapAnUnlistedCoinIsNotSpendable() public {
        _sendDailyAllowance(1_000);
        vm.startPrank(owner);
        _f().useBittyAllowList(false);

        vm.expectRevert(PaymentNotStableCoin.selector);
        vault.send(makeAddr("someone"), address(usdc), 1e6, new address[](0), new uint256[](0));
        vm.stopPrank();
    }

    function test_listingTheCoinMakesItSpendableAgain() public {
        _sendDailyAllowance(1_000);
        address[] memory one = new address[](1);
        one[0] = address(usdc);

        vm.startPrank(owner);
        _f().useBittyAllowList(false);
        _f().updateAssets(one, new address[](0));

        address to = makeAddr("someone");
        vault.send(to, address(usdc), 1e6, new address[](0), new uint256[](0));
        vm.stopPrank();
        assertEq(usdc.balanceOf(to), 1e6, "listed, so payable");
    }

    function _sendDailyAllowance(uint64 cap) internal {
        vm.prank(owner);
        vault.updateRisk(
            IBittyV1Owner.RiskSettings({
                timelock: UNCHANGED, sendDailyAllowance: cap, marketTradeDailyLossAllowance: UNCHANGED
            })
        );
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
        _f().useBittyAllowList(false);
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
        _f().autoYield(address(usdc), type(uint256).max);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 0, "swept");
        assertEq(_f().getBalances(_one(address(proto)), _one(address(usdc)))[0], 1_000e6);
    }

    /// An asset with no route is a no-op, not a revert — a fleet sweep must not fail on one asset.
    function test_autoYieldWithNoRouteIsANoOp() public {
        vm.prank(owner);
        _f().autoYield(address(usdc), type(uint256).max);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "untouched, and no revert");
    }

    function test_onlyOwnerMaySetRoutes() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
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
