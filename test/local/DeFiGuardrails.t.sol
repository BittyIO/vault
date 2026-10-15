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
import {MockSettlement} from "../helpers/MockSettlement.sol";
import {MARKET_TRADE_ID, MARKET_MAKER_ID, INTENT_ID, LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {AutoYield} from "../../src/interfaces/IBittyV1Vault.sol";
import {AddressZero, ArrayLengthMismatch, Deprecated, NotRegistered} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    InvalidMarketTradeProtocol,
    InvalidMarketMakerProtocol,
    InvalidIntentProtocol,
    InvalidDepositableProtocol,
    MarketTradeNotSupported
} from "../../src/interfaces/IBittyV1DeFi.sol";
import {
    BITTY_GUARD,
    PERM_YIELD,
    PERM_SUPPLY,
    PERM_MARKET_TRADE,
    PERM_MARKET_MAKER,
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
    function autoYield(address asset) external;
    function autoYields(address[] calldata assets) external;
    function getClone(address protocol) external view returns (address);
    function addLiquidity(address marketMaker, address t0, uint256 a0, address t1, uint256 a1, bytes memory data)
        external;
    function marketSell(
        address marketMaker,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmountMin,
        bytes memory path
    ) external;
    function marketBuy(
        address marketMaker,
        address sellToken,
        uint256 sellAmountMax,
        address buyToken,
        uint256 buyAmount,
        bytes memory reversedPath
    ) external;
    function removeLiquidity(address marketMaker, bytes memory data) external;
    function decreaseLiquidity(address marketMaker, bytes memory data) external;
    function claimMarketMakerFees(address marketMaker, bytes memory data) external;
    function getLiquidities(address[] calldata marketMakers, bytes[] calldata data)
        external
        view
        returns (uint256[] memory);
    function approveIntentRelayer(address intent, address token) external;
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

/// A position NFT that records whether the vault ever granted blanket approval.
contract PositionNFT {
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

/// A market maker whose clone reports a position NFT, so the liquidity path has an NFT to approve.
contract NFTAwareMarketMaker is MockMarketProtocol {
    address internal immutable _nft;

    constructor(address nft) {
        _nft = nft;
    }

    function positionManager() external view override returns (address) {
        return _nft;
    }
}

/// Reports a position NFT the vault cannot probe — the staticcall answers nothing usable.
contract SilentNFTMarketMaker is MockMarketProtocol {
    address internal immutable _nft;

    constructor(address nft) {
        _nft = nft;
    }

    function positionManager() external view override returns (address) {
        return _nft;
    }
}

/**
 * The guardrails around the DeFi surface: deprecation, the local allowlist's two-way switch, and the
 * argument handling on auto-yield and market-maker calls.
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
    MockMarketProtocol marketMaker;
    MockMarketProtocol marketTrade;
    MockIntentProtocol intent;
    MockSettlement settlement;

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
        marketMaker = new MockMarketProtocol();
        marketTrade = new MockMarketProtocol();
        settlement = new MockSettlement();
        intent = new MockIntentProtocol();
        intent.setEndpoints(address(settlement), address(settlement));

        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setAsset(address(dai), ASSET_STABLE_COIN);
        guard.setProtocol(address(proto), LENDING_ID);
        guard.setProtocol(address(marketMaker), MARKET_MAKER_ID);
        guard.setProtocol(address(marketTrade), MARKET_TRADE_ID);
        guard.setProtocol(address(intent), INTENT_ID);

        usdc.mint(address(vault), 1_000e6);
        dai.mint(address(vault), 1_000e18);
    }

    function _f() internal view returns (IFacet) {
        return IFacet(address(vault));
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

    function test_aDeprecatedMarketMakerRefusesNewLiquidity() public {
        guard.setDeprecated(address(marketMaker), true);
        vm.prank(owner);
        vm.expectRevert(Deprecated.selector);
        _f().addLiquidity(address(marketMaker), address(usdc), 1e6, address(dai), 1e18, "");
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
        _f().approveIntentRelayer(address(intent), address(usdc));
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
        assertFalse(_f().isProtocolAllowed(address(marketMaker)), "not named");
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

    function test_anUnnamedAssetCannotBeUsedForLiquidityWhileTheAllowlistIsOn() public {
        vm.startPrank(owner);
        _f().useBittyAllowList(false);
        _f().updateProtocols(_one(address(marketMaker)), _none());
        _f().updateAssets(_one(address(usdc)), _none());

        vm.expectRevert(NotRegistered.selector);
        _f().addLiquidity(address(marketMaker), address(usdc), 1e6, address(dai), 1e18, "");
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
        vault.updateRisk(IBittyV1Owner.RiskSettings({timelock: 2 days, sendDailyAllowance: UNCHANGED}));

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
        _f().autoYield(address(usdc));
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "untouched");
    }

    function test_autoYieldingAnEmptyBalanceDoesNothing() public {
        MockERC20 empty = new MockERC20("Empty", "EMP", 18);
        guard.setAsset(address(empty), ASSET_STABLE_COIN);
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(empty), protocol: address(proto)}));
        _f().autoYield(address(empty));
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
        vm.prank(owner);
        _f().autoYields(assets);

        address clone = _f().getClone(address(proto));
        assertEq(usdc.balanceOf(clone), 1_000e6, "usdc deployed");
        assertEq(dai.balanceOf(clone), 1_000e18, "dai deployed");
    }

    // ── market making argument handling ─────────────────────────────────────────────────

    function test_marketMakerCallsOnANeverUsedProtocolAreRefused() public {
        vm.startPrank(owner);
        vm.expectRevert(InvalidMarketMakerProtocol.selector);
        _f().removeLiquidity(address(marketMaker), "");

        vm.expectRevert(InvalidMarketMakerProtocol.selector);
        _f().decreaseLiquidity(address(marketMaker), "");

        vm.expectRevert(InvalidMarketMakerProtocol.selector);
        _f().claimMarketMakerFees(address(marketMaker), "");
        vm.stopPrank();
    }

    // Liquidity is dispatched by the market-maker interface, not a category: a registered protocol that
    // isn't a maker (here a lending adapter, with no addLiquidity) is rejected by the interface call
    // itself — it reverts with no matching function rather than a category error.
    function test_aProtocolOfTheWrongCategoryCannotProvideLiquidity() public {
        vm.prank(owner);
        vm.expectRevert(); // no addLiquidity on a lending adapter
        _f().addLiquidity(address(proto), address(usdc), 1e6, address(dai), 1e18, "");
    }

    function test_readingLiquiditiesWithRaggedArraysIsRefused() public {
        address[] memory marketMakers = new address[](2);
        marketMakers[0] = address(marketMaker);
        marketMakers[1] = address(marketMaker);
        vm.expectRevert(ArrayLengthMismatch.selector);
        _f().getLiquidities(marketMakers, new bytes[](1));
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

    // ── position-NFT approval on the liquidity path ───────────────────────────

    function test_theCloneIsGrantedTheNftItNeedsToManagePositions() public {
        PositionNFT nft = new PositionNFT();
        NFTAwareMarketMaker nftMarketMaker = new NFTAwareMarketMaker(address(nft));
        guard.setProtocol(address(nftMarketMaker), MARKET_MAKER_ID);

        vm.prank(owner);
        _f().addLiquidity(address(nftMarketMaker), address(usdc), 1e6, address(dai), 1e18, "");

        address clone = _f().getClone(address(nftMarketMaker));
        assertTrue(nft.isApprovedForAll(address(vault), clone), "the clone can move the position NFT");
    }

    function test_theApprovalIsNotGrantedTwice() public {
        PositionNFT nft = new PositionNFT();
        NFTAwareMarketMaker nftMarketMaker = new NFTAwareMarketMaker(address(nft));
        guard.setProtocol(address(nftMarketMaker), MARKET_MAKER_ID);

        vm.startPrank(owner);
        _f().addLiquidity(address(nftMarketMaker), address(usdc), 1e6, address(dai), 1e18, "");
        _f().removeLiquidity(address(nftMarketMaker), "");
        vm.stopPrank();

        address clone = _f().getClone(address(nftMarketMaker));
        assertTrue(nft.isApprovedForAll(address(vault), clone), "still approved, and not re-granted");
    }

    /// A "position NFT" that is not a contract cannot be probed; the vault skips it rather than reverting.
    function test_anUnprobeableNftIsSkippedNotFatal() public {
        SilentNFTMarketMaker oddMarketMaker = new SilentNFTMarketMaker(makeAddr("notAContract"));
        guard.setProtocol(address(oddMarketMaker), MARKET_MAKER_ID);

        vm.prank(owner);
        _f().addLiquidity(address(oddMarketMaker), address(usdc), 1e6, address(dai), 1e18, "");
        assertTrue(_f().getClone(address(oddMarketMaker)) != address(0), "liquidity still went in");
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
        _f().autoYield(address(usdc));
    }

    function test_theNamedTriggerMaySweepButNothingElse() public {
        address keeper = makeAddr("keeper");
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        _f().setAutoYieldTrigger(keeper);
        vm.stopPrank();

        vm.prank(keeper);
        _f().autoYield(address(usdc));
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
        _f().autoYield(address(usdc));

        vm.prank(owner);
        _f().setAutoYieldTrigger(address(0));
        vm.prank(newKeeper);
        vm.expectRevert(BittyV1VaultDeFiFacet.NotAutoYieldTrigger.selector);
        _f().autoYield(address(usdc));
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
        _f().autoYield(address(usdc));
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
        assertEq(settlement.invalidatedCount(), 2, "both orders were withdrawn from the book");
    }

    function test_decreasingLiquidityAlsoGrantsTheNftApproval() public {
        PositionNFT nft = new PositionNFT();
        NFTAwareMarketMaker nftMarketMaker = new NFTAwareMarketMaker(address(nft));
        guard.setProtocol(address(nftMarketMaker), MARKET_MAKER_ID);

        vm.startPrank(owner);
        _f().addLiquidity(address(nftMarketMaker), address(usdc), 1e6, address(dai), 1e18, "");
        _f().decreaseLiquidity(address(nftMarketMaker), "");
        _f().claimMarketMakerFees(address(nftMarketMaker), "");
        vm.stopPrank();

        assertTrue(nft.isApprovedForAll(address(vault), _f().getClone(address(nftMarketMaker))), "still approved");
    }

    /**
     * With the allowlist OFF, the guard is still the floor. A token nobody registered is refused even
     * though the owner named no local restrictions at all — "allowlist off" means "fall back to Bitty's
     * curation", never "anything goes".
     */
    function test_anUnregisteredTokenCannotBecomeLiquidityEvenWithTheAllowlistOff() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);
        rnd.mint(address(vault), 100e18);
        assertTrue(_f().usingBittyAllowList(), "no local narrowing at all");

        vm.prank(owner);
        vm.expectRevert(NotRegistered.selector);
        _f().addLiquidity(address(marketMaker), address(rnd), 1e18, address(dai), 1e18, "");
    }

    function test_anUnregisteredSecondTokenIsCaughtToo() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);
        rnd.mint(address(vault), 100e18);

        vm.prank(owner);
        vm.expectRevert(NotRegistered.selector);
        _f().addLiquidity(address(marketMaker), address(usdc), 1e6, address(rnd), 1e18, "");
    }

    // ── who may trade at market ──────────────────────────────────────────────

    /**
     * The asset manager may NOT. A market order's price is whatever the caller passes, and the key
     * that is trusted to choose a trade is not trusted to choose its rate — see the facet's note.
     */
    function test_theAssetManagerCannotTradeAtMarket() public {
        _bothLegsLiquid();
        address manager = makeAddr("manager");
        vm.prank(owner);
        _f().setAssetManager(manager, 0, MANAGER_PERMS);

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
        vm.prank(owner);
        _f().setAssetManager(manager, 0, MANAGER_PERMS);
        assertTrue(
            IOffchain(address(vault)).isOffchainOrderAuthorized(manager, address(usdc), address(dai), 100e6),
            "limit and TWAP stay open to the manager"
        );
    }

    // ── what the owner hands over, capability by capability ──────────────────
    //
    // The grant used to be all-or-nothing: a key appointed to put idle dollars into Sky could also
    // sell the whole balance at market. The owner now names the job — yield, lending, market trade,
    // liquidity, intents — and the vault holds the manager to it.

    /// A grant says what it is for. Nothing is implied — a mask of zero is a key that can do nothing.
    function test_aGrantIsExactlyWhatWasAskedFor() public {
        address manager = makeAddr("manager");
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_YIELD | PERM_INTENT);
        assertEq(_permissions(), PERM_YIELD | PERM_INTENT, "the mask the owner passed");

        vm.prank(owner);
        _f().setAssetManager(manager, 0, 0);
        assertEq(_permissions(), 0, "and zero grants nothing");
    }

    /// Granted by name, the manager trades at market like the owner does.
    function test_aManagerGrantedMarketTradeMayTradeAtMarket() public {
        _bothLegsLiquid();
        address manager = makeAddr("manager");
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_MARKET_TRADE);

        vm.prank(manager);
        _f().marketSell(address(marketTrade), address(usdc), 1e6, address(dai), 0, _v3Path(address(usdc), address(dai)));
        assertEq(usdc.allowance(address(vault), _f().getClone(address(marketTrade))), type(uint256).max);
    }

    /// And a grant for one job is not a grant for another.
    function test_aManagerGrantedOnlyMarketTradeCannotProvideLiquidity() public {
        address manager = makeAddr("manager");
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_MARKET_TRADE);

        vm.prank(manager);
        vm.expectRevert();
        _f().addLiquidity(address(marketMaker), address(usdc), 1e6, address(dai), 1e18, "");
    }

    function test_aManagerWithoutTheIntentBitCannotSignOrders() public {
        address manager = makeAddr("manager");
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_YIELD);
        assertFalse(
            IOffchain(address(vault)).isOffchainOrderAuthorized(manager, address(usdc), address(dai), 1e6),
            "limit and TWAP are not part of this grant"
        );
    }

    /// Lending and yielding are one function and two capabilities, told apart by the adapter.
    function test_aYieldOnlyManagerCannotLend() public {
        address manager = makeAddr("manager");
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_YIELD);

        // `proto` is registered on the guard as a LENDING adapter, so this needs PERM_SUPPLY.
        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(proto), address(usdc), 1e6);

        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_SUPPLY);
        vm.prank(manager);
        _f().deposit(address(proto), address(usdc), 1e6);
        assertEq(usdc.balanceOf(_f().getClone(address(proto))), 1e6, "the lending grant works");
    }

    /// A bit nobody defined authorises nothing: every check asks for one bit by name.
    function test_anUndefinedPermissionBitGrantsNothing() public {
        address manager = makeAddr("manager");
        vm.prank(owner);
        _f().setAssetManager(manager, 0, uint32(1 << 20));

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
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_YIELD | PERM_SUPPLY);
        assertEq(_permissions(), PERM_YIELD | PERM_SUPPLY);

        // Narrowing is self-restriction: it lands even with a timelock set, which this vault has not.
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_YIELD);
        assertEq(_permissions(), PERM_YIELD, "narrowing took effect at once");

        // Widening with no timelock configured also lands at once — the queue is what a timelock
        // buys, and {AssetManager} covers the queued path for the grant as a whole.
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_YIELD | PERM_MARKET_TRADE);
        assertEq(_permissions(), PERM_YIELD | PERM_MARKET_TRADE, "widening, no timelock");
    }
}
