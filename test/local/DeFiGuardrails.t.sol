// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN, ASSET_AMM_LIQUID} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {MockMarketProtocol} from "../helpers/MockMarketProtocol.sol";
import {MockIntentProtocol} from "../helpers/MockIntentProtocol.sol";
import {MARKET_TRADE_ID, INTENT_ID, LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {AutoYield} from "../../src/interfaces/IBittyV1Vault.sol";
import {AddressZero, ArrayLengthMismatch, Deprecated, NotRegistered} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    InvalidMarketTradeProtocol,
    InvalidIntentProtocol,
    InvalidDepositableProtocol,
    MarketTradeNotSupported
} from "../../src/interfaces/IBittyV1DeFi.sol";
import {
    BITTY_GUARD,
    MIN_RISK_TIMELOCK,
    PERM_YIELD,
    PERM_SUPPLY,
    PERM_MARKET_TRADE,
    PERM_INTENT
} from "../../src/logic/Constants.sol";

/*
 * The capabilities these tests appoint a manager for: the jobs a managed vault is actually given —
 * yield, lending and the intent orders it signs — and NOT trading at market, which the owner has to
 * grant by name. See {PERM_YIELD} and the note above it.
 */
uint32 constant MANAGER_PERMS = PERM_YIELD | PERM_SUPPLY | PERM_INTENT;

// Market buy/sell requires BOTH legs to carry {ASSET_AMM_LIQUID}; it is owner-curated data on the
// guard, so the guard contract is unchanged.

interface IOffchain {
    function isOffchainOrderAuthorized(address signer, address sellToken, address buyToken, uint256 sellAmount)
        external
        view
        returns (bool);
}

interface IFacet {
    function deposit(address protocol, address asset, uint256 amount) external;
    function updateAssets(address[] calldata add, address[] calldata remove) external;
    function updateProtocols(address[] calldata add, address[] calldata remove) external;
    function isAssetAllowed(address asset) external view returns (bool);
    function isProtocolAllowed(address protocol) external view returns (bool);
    function usingBittyAllowList() external view returns (bool);
    function useBittyAllowList(bool use) external;
    function setAutoYielding(AutoYield calldata route) external;
    function setAutoYieldings(AutoYield[] calldata routes) external;
    function getAutoYieldings(address[] calldata assets) external view returns (address[] memory);
    function autoYield(address asset, uint256 amount) external;
    function autoYields(address[] calldata assets, uint256[] calldata amounts) external;
    function getClone(address protocol) external view returns (address);
    function marketSell(
        address marketTrade,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmountMin,
        bytes memory path
    ) external;
    function marketBuy(
        address marketTrade,
        address sellToken,
        uint256 sellAmountMax,
        address buyToken,
        uint256 buyAmount,
        bytes memory reversedPath
    ) external;
    function approveIntentSpender(address intent, address token) external;
    function cancelIntentOrder(address intent, bytes calldata uid) external;
    function setAutoYieldTrigger(address trigger) external;
    function autoYieldTrigger() external view returns (address);
    function cancelIntentOrders(address intent, bytes[] calldata uids) external;
    function guard() external view returns (address);
    function setAssetManager(address assetManager_, uint64 expiresAt, uint32 permissions) external;
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
}

/**
 * The guardrails around the DeFi surface: deprecation, the local allowlist's two-way switch, and the
 * argument handling on auto-yield calls.
 *
 * Deprecation is the guard's one-way exit — a protocol the vault may still WITHDRAW from but must not
 * put new money into. The allowlist is the owner's own narrowing, and it tightens instantly but loosens
 * on a timelock, so a stolen key cannot widen the vault's reach in one transaction.
 */
contract DeFiGuardrailsTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 dai;
    MockLendingProtocol proto;
    MockMarketProtocol marketTrade;
    MockIntentProtocol intent;
    address intentSpender = makeAddr("intentSpender");

    address owner = makeAddr("owner");
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
        dai = new MockERC20("Dai", "DAI", 18);
        proto = new MockLendingProtocol();
        marketTrade = new MockMarketProtocol();
        intent = new MockIntentProtocol(intentSpender);

        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setAsset(address(dai), ASSET_STABLE_COIN);
        guard.setProtocol(address(proto), LENDING_ID);
        guard.setProtocol(address(marketTrade), MARKET_TRADE_ID);
        guard.setProtocol(address(intent), INTENT_ID);

        usdc.mint(address(vault), 1_000e6);
        dai.mint(address(vault), 1_000e18);
    }

    function _f() internal view returns (IFacet) {
        return IFacet(address(vault));
    }

    /**
     * Grant `manager` and let it land: a new vault's timelock is a day, so even the first grant waits.
     */
    function _grant(address manager, uint64 expiresAt, uint32 permissions) internal {
        vm.prank(owner);
        _f().setAssetManager(manager, expiresAt, permissions);
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
    }

    function _permissions() internal view returns (uint32 permissions) {
        (,,,, permissions,) = _f().getAssetManagerSettings();
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    /**
     * A packed Uniswap v3 path: `token ‖ fee ‖ token`, one hop.
     */
    function _v3Path(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, uint24(3000), b);
    }

    /**
     * Two hops, through `mid`.
     */
    function _v3Path(address a, address mid, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, uint24(3000), mid, uint24(3000), b);
    }

    function _bothLegsLiquid() internal {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
    }

    // ── deprecation ───────────────────────────────────────────────────────────

    function test_aDeprecatedProtocolTakesNoNewDeposits() public {
        guard.setDeprecated(address(proto), true);
        vm.prank(owner);
        vm.expectRevert(InvalidDepositableProtocol.selector);
        _f().deposit(address(proto), address(usdc), 10e6);
    }

    function test_moneyAlreadyInADeprecatedProtocolStillComesOut() public {
        vm.prank(owner);
        _f().deposit(address(proto), address(usdc), 100e6);
        guard.setDeprecated(address(proto), true);

        vm.prank(owner);
        BittyV1Vault(payable(address(vault)));
        (bool ok,) = address(vault)
            .call(abi.encodeWithSignature("withdraw(address,address,uint256)", address(proto), address(usdc), 100e6));
        assertTrue(ok, "deprecation is an exit, not a trap");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "everything came back");
    }

    // ── market buy / sell: both legs must be flagged market-tradable ─────────────────
    // A market swap is only for assets the guard has flagged market-tradable, on BOTH legs. Assets
    // without the flag are limit-order (CoW) only, so a market swap on either an unflagged sell token
    // or an unflagged buy token is refused before it ever reaches the pool.

    function test_marketSell_bothLegsMarketTradable_reachesTheProtocol() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        _f().marketSell(address(marketTrade), address(usdc), 1e6, address(dai), 0, _v3Path(address(usdc), address(dai)));
        // The gate passed and the swap dispatched to the adapter clone (which the vault approved to spend).
        assertEq(
            usdc.allowance(address(vault), _f().getClone(address(marketTrade))),
            type(uint256).max,
            "sell token approved to the adapter clone"
        );
    }

    function test_marketSell_sellLegNotMarketTradable_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN); // sell leg: not flagged market-tradable
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        vm.expectRevert(MarketTradeNotSupported.selector);
        _f().marketSell(address(marketTrade), address(usdc), 1e6, address(dai), 0, "");
    }

    function test_marketSell_buyLegNotMarketTradable_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN); // buy leg: not flagged market-tradable
        vm.prank(owner);
        vm.expectRevert(MarketTradeNotSupported.selector);
        _f().marketSell(address(marketTrade), address(usdc), 1e6, address(dai), 0, "");
    }

    function test_marketBuy_bothLegsMarketTradable_reachesTheProtocol() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        _f()
            .marketBuy(
                address(marketTrade), address(usdc), 1e6, address(dai), 1e18, _v3Path(address(dai), address(usdc))
            );
        assertEq(
            usdc.allowance(address(vault), _f().getClone(address(marketTrade))),
            type(uint256).max,
            "sell token approved to the adapter clone"
        );
    }

    function test_marketBuy_sellLegNotMarketTradable_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN); // sell leg: not flagged market-tradable
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        vm.expectRevert(MarketTradeNotSupported.selector);
        _f().marketBuy(address(marketTrade), address(usdc), 1e6, address(dai), 1e18, "");
    }

    function test_marketBuy_buyLegNotMarketTradable_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN); // buy leg: not flagged market-tradable
        vm.prank(owner);
        vm.expectRevert(MarketTradeNotSupported.selector);
        _f().marketBuy(address(marketTrade), address(usdc), 1e6, address(dai), 1e18, "");
    }

    // The protocol gate comes BEFORE the asset gates: a market order names a trade venue, and anything that is
    // not one (or one the guard has retired) is refused up front, whatever the legs look like.

    function test_marketSell_throughAProtocolOfTheWrongCategory_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        vm.expectRevert(InvalidMarketTradeProtocol.selector);
        _f().marketSell(address(proto), address(usdc), 1e6, address(dai), 0, "");
    }

    function test_marketSell_throughADeprecatedProtocol_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setDeprecated(address(marketTrade), true);
        vm.prank(owner);
        vm.expectRevert(Deprecated.selector);
        _f().marketSell(address(marketTrade), address(usdc), 1e6, address(dai), 0, "");
    }

    function test_marketBuy_throughAProtocolOfTheWrongCategory_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        vm.expectRevert(InvalidMarketTradeProtocol.selector);
        _f().marketBuy(address(proto), address(usdc), 1e6, address(dai), 1e18, "");
    }

    function test_marketBuy_throughADeprecatedProtocol_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setDeprecated(address(marketTrade), true);
        vm.prank(owner);
        vm.expectRevert(Deprecated.selector);
        _f().marketBuy(address(marketTrade), address(usdc), 1e6, address(dai), 1e18, "");
    }

    function test_aDeprecatedIntentProtocolSignsNothingNew() public {
        guard.setDeprecated(address(intent), true);
        vm.prank(owner);
        vm.expectRevert(Deprecated.selector);
        _f().approveIntentSpender(address(intent), address(usdc));
    }

    // ── the local allowlist ───────────────────────────────────────────────────

    function test_theAllowlistTightensImmediately() public {
        vm.startPrank(owner);
        _f().useBittyAllowList(false);
        assertFalse(_f().usingBittyAllowList(), "on the moment it is asked for");
        assertFalse(_f().isAssetAllowed(address(usdc)), "and nothing is named yet");
        vm.stopPrank();
    }

    function test_underTheAllowlistOnlyNamedThingsAreReachable() public {
        vm.startPrank(owner);
        _f().useBittyAllowList(false);
        _f().updateAssets(_one(address(usdc)), _none());
        _f().updateProtocols(_one(address(proto)), _none());
        vm.stopPrank();

        assertTrue(_f().isAssetAllowed(address(usdc)), "named");
        assertFalse(_f().isAssetAllowed(address(dai)), "not named");
        assertTrue(_f().isProtocolAllowed(address(proto)), "named");
        assertFalse(_f().isProtocolAllowed(address(marketTrade)), "not named");
    }

    function test_theAllowlistCannotNameSomethingTheGuardRejects() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);
        vm.startPrank(owner);
        _f().useBittyAllowList(false);
        vm.expectRevert(NotRegistered.selector);
        _f().updateAssets(_one(address(rnd)), _none());
        vm.stopPrank();
    }

    function test_theAllowlistCannotNameAProtocolTheGuardRejects() public {
        vm.startPrank(owner);
        _f().useBittyAllowList(false);
        vm.expectRevert(NotRegistered.selector);
        _f().updateProtocols(_one(makeAddr("nowhere")), _none());
        vm.stopPrank();
    }

    function test_removingAnAssetFromTheAllowlistClosesIt() public {
        vm.startPrank(owner);
        _f().useBittyAllowList(false);
        _f().updateAssets(_one(address(usdc)), _none());
        _f().updateAssets(_none(), _one(address(usdc)));
        vm.stopPrank();
        assertFalse(_f().isAssetAllowed(address(usdc)), "no longer named");
    }

    function test_removingAProtocolFromTheAllowlistClosesIt() public {
        vm.startPrank(owner);
        _f().useBittyAllowList(false);
        _f().updateProtocols(_one(address(proto)), _none());
        _f().updateProtocols(_none(), _one(address(proto)));
        vm.stopPrank();
        assertFalse(_f().isProtocolAllowed(address(proto)), "no longer named");
    }

    function test_anUnnamedAssetCannotBeTradedWhileTheAllowlistIsOn() public {
        _bothLegsLiquid();
        vm.startPrank(owner);
        _f().useBittyAllowList(false);
        _f().updateProtocols(_one(address(marketTrade)), _none());
        _f().updateAssets(_one(address(usdc)), _none());

        vm.expectRevert(NotRegistered.selector);
        _f().marketSell(address(marketTrade), address(usdc), 1e6, address(dai), 0, _v3Path(address(usdc), address(dai)));
        vm.stopPrank();
    }

    /**
     * Both directions apply in the call that asks for them, timelock or no timelock. Returning to
     * the catalogue is a loosening and used to wait; it stopped waiting because the set it widens to
     * is Bitty's vetted one, and because a delay meant an owner could not try it without committing
     * to it. See {DeFiLogic-deactivateOwnAllowList}.
     */
    function test_theAllowListSwitchIsImmediateInBothDirections() public {
        vm.startPrank(owner);
        vault.updateRisk(
            IBittyV1Owner.RiskSettings({
                timelock: 2 days, sendDailyAllowance: UNCHANGED, marketTradeDailyLossAllowance: UNCHANGED
            })
        );

        _f().useBittyAllowList(false);
        assertFalse(_f().usingBittyAllowList(), "narrowed at once");

        _f().useBittyAllowList(true);
        assertTrue(_f().usingBittyAllowList(), "and widened at once");
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        assertTrue(_f().usingBittyAllowList(), "with nothing left to arrive later");
    }

    function test_choosingTheCatalogueWhenAlreadyOnItIsANoOp() public {
        vm.prank(owner);
        _f().useBittyAllowList(true);
        assertTrue(_f().usingBittyAllowList());
    }

    // ── auto-yield routes ─────────────────────────────────────────────────────

    function test_aRouteCannotBeSetForTheZeroAsset() public {
        vm.prank(owner);
        vm.expectRevert(AddressZero.selector);
        _f().setAutoYielding(AutoYield({asset: address(0), protocol: address(proto)}));
    }

    function test_aRouteToTheZeroProtocolClearsIt() public {
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        assertEq(_f().getAutoYieldings(_one(address(usdc)))[0], address(proto), "set");

        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(0)}));
        assertEq(_f().getAutoYieldings(_one(address(usdc)))[0], address(0), "cleared");
        vm.stopPrank();
    }

    function test_aRouteToAProtocolTheGuardRejectsIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(InvalidDepositableProtocol.selector);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: makeAddr("nowhere")}));
    }

    function test_severalRoutesAreSetInOneCall() public {
        AutoYield[] memory routes = new AutoYield[](2);
        routes[0] = AutoYield({asset: address(usdc), protocol: address(proto)});
        routes[1] = AutoYield({asset: address(dai), protocol: address(proto)});
        vm.prank(owner);
        _f().setAutoYieldings(routes);

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        address[] memory got = _f().getAutoYieldings(assets);
        assertEq(got[0], address(proto));
        assertEq(got[1], address(proto));
    }

    function test_autoYieldingAnAssetWithNoRouteDoesNothing() public {
        vm.prank(owner);
        _f().autoYield(address(usdc), type(uint256).max);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "untouched");
    }

    function test_autoYieldingAnEmptyBalanceDoesNothing() public {
        MockERC20 empty = new MockERC20("Empty", "EMP", 18);
        guard.setAsset(address(empty), ASSET_STABLE_COIN);
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(empty), protocol: address(proto)}));
        _f().autoYield(address(empty), type(uint256).max);
        vm.stopPrank();
        assertEq(_f().getClone(address(proto)), address(0), "nothing to deploy, so nothing was cloned");
    }

    function test_severalAssetsAreSweptInOneCall() public {
        AutoYield[] memory routes = new AutoYield[](2);
        routes[0] = AutoYield({asset: address(usdc), protocol: address(proto)});
        routes[1] = AutoYield({asset: address(dai), protocol: address(proto)});
        vm.prank(owner);
        _f().setAutoYieldings(routes);

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        uint256[] memory all = new uint256[](2);
        all[0] = type(uint256).max;
        all[1] = type(uint256).max;
        vm.prank(owner);
        _f().autoYields(assets, all);

        address clone = _f().getClone(address(proto));
        assertEq(usdc.balanceOf(clone), 1_000e6, "usdc deployed");
        assertEq(dai.balanceOf(clone), 1_000e18, "dai deployed");
    }

    /// The keeper names the amount, so the fee float stays behind instead of being swept with the rest.
    function test_autoYieldDepositsOnlyTheNamedAmount() public {
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        _f().autoYield(address(usdc), 990e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(_f().getClone(address(proto))), 990e6, "deposited");
        assertEq(usdc.balanceOf(address(vault)), 10e6, "the float stays");
    }

    /// Capped, not refused: the balance can move between the keeper reading it and the sweep landing.
    function test_autoYieldCapsTheAmountAtTheFreeBalance() public {
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        _f().autoYield(address(usdc), 5_000e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 0, "everything there was");
    }

    function test_autoYieldsRefusesRaggedAmounts() public {
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        _f().autoYields(assets, new uint256[](1));
    }

    function test_aNonIntentProtocolCannotBeAskedToCancel() public {
        vm.prank(owner);
        vm.expectRevert(InvalidIntentProtocol.selector);
        _f().cancelIntentOrder(address(proto), hex"00");
    }

    // ── the view helpers answer for things the guard never registered ─────────

    function test_anUnregisteredAssetIsNeverAllowed() public {
        assertFalse(_f().isAssetAllowed(makeAddr("nothing")), "the guard does not know it");
    }

    function test_anUnregisteredProtocolIsNeverAllowed() public {
        assertFalse(_f().isProtocolAllowed(makeAddr("nothing")), "the guard does not know it");
    }

    function test_aNonStablecoinIsNotSpendableUnderACap() public {
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        guard.setAsset(address(wbtc), 2);
        assertFalse(vault.isStableCoinAllowed(address(wbtc)), "registered, but the wrong category");
    }

    function test_anUnregisteredAssetIsNotASpendableStablecoin() public {
        assertFalse(vault.isStableCoinAllowed(makeAddr("nothing")), "not registered at all");
    }

    function test_aRegisteredStablecoinIsSpendable() public view {
        assertTrue(vault.isStableCoinAllowed(address(usdc)));
    }

    // ── the delegated auto-yield trigger ──────────────────────────────────────

    function test_thereIsNoDelegatedTriggerByDefault() public view {
        assertEq(_f().autoYieldTrigger(), address(0), "only the owner, until one is named");
    }

    function test_aStrangerCannotTriggerASweep() public {
        vm.prank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BittyV1VaultDeFiFacet.NotAutoYieldTrigger.selector);
        _f().autoYield(address(usdc), type(uint256).max);
    }

    function test_theNamedTriggerMaySweepButNothingElse() public {
        address keeper = makeAddr("keeper");
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        _f().setAutoYieldTrigger(keeper);
        vm.stopPrank();

        vm.prank(keeper);
        _f().autoYield(address(usdc), type(uint256).max);
        assertEq(usdc.balanceOf(_f().getClone(address(proto))), 1_000e6, "the keeper swept it");

        vm.prank(keeper);
        vm.expectRevert();
        _f().setAutoYielding(AutoYield({asset: address(dai), protocol: address(proto)}));
    }

    function test_theTriggerCanBeRotatedAndRevoked() public {
        address oldKeeper = makeAddr("oldKeeper");
        address newKeeper = makeAddr("newKeeper");
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        _f().setAutoYieldTrigger(oldKeeper);
        _f().setAutoYieldTrigger(newKeeper);
        vm.stopPrank();

        vm.prank(oldKeeper);
        vm.expectRevert(BittyV1VaultDeFiFacet.NotAutoYieldTrigger.selector);
        _f().autoYield(address(usdc), type(uint256).max);

        vm.prank(owner);
        _f().setAutoYieldTrigger(address(0));
        vm.prank(newKeeper);
        vm.expectRevert(BittyV1VaultDeFiFacet.NotAutoYieldTrigger.selector);
        _f().autoYield(address(usdc), type(uint256).max);
    }

    function test_onlyTheOwnerNamesTheTrigger() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        _f().setAutoYieldTrigger(makeAddr("keeper"));
    }

    function test_theOwnerAlwaysSweepsEvenWithATriggerNamed() public {
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        _f().setAutoYieldTrigger(makeAddr("keeper"));
        _f().autoYield(address(usdc), type(uint256).max);
        vm.stopPrank();
        assertEq(usdc.balanceOf(_f().getClone(address(proto))), 1_000e6, "naming a trigger does not displace the owner");
    }

    function test_theVaultReportsTheGuardItTrusts() public view {
        assertEq(_f().guard(), BITTY_GUARD, "one shared registry, named in code");
    }

    function test_severalIntentOrdersAreCancelledInOneCall() public {
        vm.prank(owner);
        _f().updateProtocols(_one(address(intent)), _none());

        bytes[] memory uids = new bytes[](2);
        uids[0] = hex"aa";
        uids[1] = hex"bb";
        vm.prank(owner);
        _f().cancelIntentOrders(address(intent), uids);
        MockIntentProtocol clone = MockIntentProtocol(_f().getClone(address(intent)));
        assertEq(clone.cancelledCount(), 2, "both orders were cancelled on the vault's clone");
        assertTrue(clone.isOrderCancelled(hex"bb"));
    }

    /**
     * A deprecated intent protocol keeps settling the vault's in-flight orders (isValidSignature still
     * walks the deprecated tier), so those orders must stay cancellable even though nothing new may be
     * approved for it.
     */
    function test_aDeprecatedIntentProtocolCanStillCancel() public {
        vm.prank(owner);
        _f().updateProtocols(_one(address(intent)), _none());
        guard.setDeprecated(address(intent), true);

        vm.prank(owner);
        _f().cancelIntentOrder(address(intent), hex"aa");
        assertEq(MockIntentProtocol(_f().getClone(address(intent))).cancelledCount(), 1);
    }

    /// The vault is the clone's owner; nobody else can write its cancellations.
    function test_onlyTheVaultCancelsOnItsClone() public {
        vm.prank(owner);
        _f().updateProtocols(_one(address(intent)), _none());
        MockIntentProtocol clone = MockIntentProtocol(_f().getClone(address(intent)));
        bytes[] memory uids = new bytes[](1);
        uids[0] = hex"aa";
        vm.prank(owner);
        vm.expectRevert("only the vault");
        clone.cancelOrders(uids);
    }

    /**
     * With the allowlist OFF, the guard is still the floor. A token nobody registered is refused even
     * though the owner named no local restrictions at all — "allowlist off" means "fall back to Bitty's
     * curation", never "anything goes".
     */
    function test_anUnregisteredTokenCannotBeSoldEvenWithTheAllowlistOff() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);
        rnd.mint(address(vault), 100e18);
        assertTrue(_f().usingBittyAllowList(), "no local narrowing at all");

        vm.prank(owner);
        vm.expectRevert(NotRegistered.selector);
        _f().marketSell(address(marketTrade), address(rnd), 1e18, address(dai), 0, _v3Path(address(rnd), address(dai)));
    }

    function test_anUnregisteredTokenCannotBeBoughtEither() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);

        vm.prank(owner);
        vm.expectRevert(NotRegistered.selector);
        _f().marketSell(address(marketTrade), address(usdc), 1e6, address(rnd), 0, _v3Path(address(usdc), address(rnd)));
    }

    // ── who may trade at market ──────────────────────────────────────────────

    /**
     * The asset manager may NOT. A market order's price is whatever the caller passes, and the key
     * that is trusted to choose a trade is not trusted to choose its rate — see the facet's note.
     */
    function test_theAssetManagerCannotTradeAtMarket() public {
        _bothLegsLiquid();
        address manager = makeAddr("manager");
        _grant(manager, uint64(block.timestamp + 365 days), MANAGER_PERMS);

        vm.prank(manager);
        vm.expectRevert();
        _f().marketSell(address(marketTrade), address(usdc), 1e6, address(dai), 0, _v3Path(address(usdc), address(dai)));

        vm.prank(manager);
        vm.expectRevert();
        _f()
            .marketBuy(
                address(marketTrade), address(usdc), 1e6, address(dai), 1e18, _v3Path(address(dai), address(usdc))
            );
    }

    /// And the manager keeps the surface it is there for: intent orders it signs off chain.
    function test_theAssetManagerStillSignsIntentOrders() public {
        address manager = makeAddr("manager");
        _grant(manager, uint64(block.timestamp + 365 days), MANAGER_PERMS);
        assertTrue(
            IOffchain(address(vault)).isOffchainOrderAuthorized(manager, address(usdc), address(dai), 100e6),
            "limit and TWAP stay open to the manager"
        );
    }

    // ── what the owner hands over, capability by capability ──────────────────
    //
    // The grant used to be all-or-nothing: a key appointed to put idle dollars into Sky could also
    // sell the whole balance at market. The owner now names the job — yield, lending, market trade,
    // intents — and the vault holds the manager to it.

    /// A grant says what it is for. Nothing is implied — a mask of zero is a key that can do nothing.
    function test_aGrantIsExactlyWhatWasAskedFor() public {
        address manager = makeAddr("manager");
        uint64 expiry = uint64(block.timestamp + 365 days);
        _grant(manager, expiry, PERM_YIELD | PERM_INTENT);
        assertEq(_permissions(), PERM_YIELD | PERM_INTENT, "the mask the owner passed");

        vm.prank(owner);
        _f().setAssetManager(manager, expiry, 0);
        assertEq(_permissions(), 0, "and zero grants nothing");
    }

    /// Granted by name, the manager trades at market like the owner does.
    function test_aManagerGrantedMarketTradeMayTradeAtMarket() public {
        _bothLegsLiquid();
        address manager = makeAddr("manager");
        _grant(manager, uint64(block.timestamp + 365 days), PERM_MARKET_TRADE);

        vm.prank(manager);
        _f().marketSell(address(marketTrade), address(usdc), 1e6, address(dai), 0, _v3Path(address(usdc), address(dai)));
        assertEq(usdc.allowance(address(vault), _f().getClone(address(marketTrade))), type(uint256).max);
    }

    function test_aManagerWithoutTheIntentBitCannotSignOrders() public {
        address manager = makeAddr("manager");
        _grant(manager, uint64(block.timestamp + 365 days), PERM_YIELD);
        assertFalse(
            IOffchain(address(vault)).isOffchainOrderAuthorized(manager, address(usdc), address(dai), 1e6),
            "limit and TWAP are not part of this grant"
        );
    }

    /// Lending and yielding are one function and two capabilities, told apart by the adapter.
    function test_aYieldOnlyManagerCannotLend() public {
        address manager = makeAddr("manager");
        _grant(manager, uint64(block.timestamp + 365 days), PERM_YIELD);

        // `proto` is registered on the guard as a LENDING adapter, so this needs PERM_SUPPLY.
        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);

        _grant(manager, uint64(block.timestamp + 365 days), PERM_SUPPLY);
        vm.prank(manager);
        _f().deposit(address(proto), address(usdc), 1e6);
        assertEq(usdc.balanceOf(_f().getClone(address(proto))), 1e6, "the lending grant works");
    }

    /// A bit nobody defined authorises nothing: every check asks for one bit by name.
    function test_anUndefinedPermissionBitGrantsNothing() public {
        address manager = makeAddr("manager");
        _grant(manager, uint64(block.timestamp + 365 days), uint32(1 << 20));

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);
    }

    /**
     * Dropping a capability lands at once; adding one waits. The same rule the allow list and the
     * grant's own expiry follow, so a stolen owner key cannot widen a manager's reach in one go.
     */
    function test_narrowingIsImmediateAndWideningQueues() public {
        address manager = makeAddr("manager");
        uint64 expiry = uint64(block.timestamp + 365 days);
        _grant(manager, expiry, PERM_YIELD | PERM_SUPPLY);
        assertEq(_permissions(), PERM_YIELD | PERM_SUPPLY);

        // Narrowing is self-restriction: it lands at once, whatever the timelock.
        vm.prank(owner);
        _f().setAssetManager(manager, expiry, PERM_YIELD);
        assertEq(_permissions(), PERM_YIELD, "narrowing took effect at once");

        // Widening waits out the timelock, which every vault has - a day until the owner sets one.
        vm.prank(owner);
        _f().setAssetManager(manager, expiry, PERM_YIELD | PERM_MARKET_TRADE);
        assertEq(_permissions(), PERM_YIELD, "widening is queued");
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        assertEq(_permissions(), PERM_YIELD | PERM_MARKET_TRADE, "and lands after the timelock");
    }
}
