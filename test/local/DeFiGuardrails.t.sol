// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {MockAMMProtocol} from "../helpers/MockAMMProtocol.sol";
import {MockIntentProtocol} from "../helpers/MockIntentProtocol.sol";
import {MockSettlement} from "../helpers/MockSettlement.sol";
import {AMM_ID, MARKET_TRADE_ID, MARKET_MAKER_ID, INTENT_ID, LENDING_ID} from "../helpers/CategoryIds.sol";
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
import {
    RouteCommandNotAllowed,
    RouteRecipientNotAllowed,
    RouteHookNotAllowed,
    RouteMalformed
} from "../../src/logic/RouteGuard.sol";
import {UniversalRoute} from "protocol-contracts/src/libs/uniswap/universal/UniversalRouter.sol";

/*
 * The capabilities these tests appoint a manager for: the jobs a managed vault is actually given —
 * yield, lending and the intent orders it signs — and NOT trading at market, which the owner has to
 * grant by name. See {PERM_YIELD} and the note above it.
 */
uint32 constant MANAGER_PERMS = PERM_YIELD | PERM_SUPPLY | PERM_INTENT;

// The AMM-liquid category bit (mirrors DeFiLogic.ASSET_AMM_LIQUID). Market buy/sell requires BOTH
// legs to carry it; it is owner-curated data on the guard, so the guard contract is unchanged.
uint8 constant ASSET_AMM_LIQUID = 4;

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
    function allowlistEnabled() external view returns (bool);
    function enableAllowlist() external;
    function setAutoYielding(AutoYield calldata route) external;
    function setAutoYieldings(AutoYield[] calldata routes) external;
    function getAutoYieldings(address[] calldata assets) external view returns (address[] memory);
    function autoYield(address asset) external;
    function autoYields(address[] calldata assets) external;
    function getClone(address protocol) external view returns (address);
    function addLiquidity(address amm, address t0, uint256 a0, address t1, uint256 a1, bytes memory data) external;
    function marketSell(
        address amm,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmountMin,
        bytes memory path
    ) external;
    function marketBuy(
        address amm,
        address sellToken,
        uint256 sellAmountMax,
        address buyToken,
        uint256 buyAmount,
        bytes memory reversedPath
    ) external;
    function removeLiquidity(address amm, bytes memory data) external;
    function decreaseLiquidity(address amm, bytes memory data) external;
    function claimAMMFees(address amm, bytes memory data) external;
    function getLiquidities(address[] calldata amms, bytes[] calldata data) external view returns (uint256[] memory);
    function approveIntentRelayer(address intent, address token) external;
    function cancelIntentOrder(address intent, bytes calldata uid) external;
    function setAutoYieldTrigger(address trigger) external;
    function autoYieldTrigger() external view returns (address);
    function cancelIntentOrders(address intent, bytes[] calldata uids) external;
    function guard() external view returns (address);
    function setAssetManager(address assetManager_, uint64 expiresAt, uint32 permissions) external;
    function assetManagerPermissions() external view returns (uint32);
}

/**
 *  Mirrors {RouteGuard}'s v4 structs, so a test can encode the action parameters it decodes.
 */
struct RouteGuardV4Key {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct RouteGuardV4Single {
    RouteGuardV4Key poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

/// A position NFT that records whether the vault ever granted blanket approval.
contract PositionNFT {
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

/// An AMM whose clone reports a position NFT, so the liquidity path has an NFT to approve.
contract NFTAwareAMM is MockAMMProtocol {
    address internal immutable _nft;

    constructor(address nft) {
        _nft = nft;
    }

    function positionManager() external view override returns (address) {
        return _nft;
    }
}

/// Reports a position NFT the vault cannot probe — the staticcall answers nothing usable.
contract SilentNFTAMM is MockAMMProtocol {
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
 * argument handling on auto-yield and AMM calls.
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
    MockAMMProtocol amm;
    MockAMMProtocol tradeAmm;
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
        amm = new MockAMMProtocol();
        tradeAmm = new MockAMMProtocol();
        settlement = new MockSettlement();
        intent = new MockIntentProtocol();
        intent.setEndpoints(address(settlement), address(settlement));

        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setAsset(address(dai), ASSET_STABLE_COIN);
        guard.setProtocol(address(proto), LENDING_ID);
        guard.setProtocol(address(amm), MARKET_MAKER_ID);
        guard.setProtocol(address(tradeAmm), MARKET_TRADE_ID);
        guard.setProtocol(address(intent), INTENT_ID);

        usdc.mint(address(vault), 1_000e6);
        dai.mint(address(vault), 1_000e18);
    }

    function _f() internal view returns (IFacet) {
        return IFacet(address(vault));
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

    /**
     * A tagged Universal route carrying one command and its input.
     */
    function _universal(uint8 command, bytes memory input) internal view returns (bytes memory) {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = input;
        return UniversalRoute.encode(abi.encodePacked(bytes1(command)), inputs, block.timestamp + 60);
    }

    /**
     * The Universal Router's `V3_SWAP_EXACT_IN` input, as the quoting service encodes it.
     */
    function _v3SwapIn(address recipient, bytes memory path) internal pure returns (bytes memory) {
        return abi.encode(recipient, uint256(1e6), uint256(0), path, true, new uint256[](0));
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

    function test_aDeprecatedAmmRefusesNewLiquidity() public {
        guard.setDeprecated(address(amm), true);
        vm.prank(owner);
        vm.expectRevert(Deprecated.selector);
        _f().addLiquidity(address(amm), address(usdc), 1e6, address(dai), 1e18, "");
    }

    // ── market buy / sell: both legs must be flagged AMM-liquid ─────────────────
    // A market (AMM) swap is only for assets the guard has flagged AMM-liquid, on BOTH legs. Assets
    // without the flag are limit-order (CoW) only, so a market swap on either an unflagged sell token
    // or an unflagged buy token is refused before it ever reaches the pool.

    function test_marketSell_bothLegsAmmLiquid_reachesTheAmm() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        _f().marketSell(address(tradeAmm), address(usdc), 1e6, address(dai), 0, _v3Path(address(usdc), address(dai)));
        // The gate passed and the swap dispatched to the AMM clone (which the vault approved to spend).
        assertEq(
            usdc.allowance(address(vault), _f().getClone(address(tradeAmm))),
            type(uint256).max,
            "sell token approved to the amm clone"
        );
    }

    function test_marketSell_sellLegNotAmmLiquid_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN); // sell leg: no AMM-liquid flag
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        vm.expectRevert(MarketTradeNotSupported.selector);
        _f().marketSell(address(tradeAmm), address(usdc), 1e6, address(dai), 0, "");
    }

    function test_marketSell_buyLegNotAmmLiquid_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN); // buy leg: no AMM-liquid flag
        vm.prank(owner);
        vm.expectRevert(MarketTradeNotSupported.selector);
        _f().marketSell(address(tradeAmm), address(usdc), 1e6, address(dai), 0, "");
    }

    function test_marketBuy_bothLegsAmmLiquid_reachesTheAmm() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        _f().marketBuy(address(tradeAmm), address(usdc), 1e6, address(dai), 1e18, _v3Path(address(dai), address(usdc)));
        assertEq(
            usdc.allowance(address(vault), _f().getClone(address(tradeAmm))),
            type(uint256).max,
            "sell token approved to the amm clone"
        );
    }

    function test_marketBuy_sellLegNotAmmLiquid_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN); // sell leg: no AMM-liquid flag
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        vm.expectRevert(MarketTradeNotSupported.selector);
        _f().marketBuy(address(tradeAmm), address(usdc), 1e6, address(dai), 1e18, "");
    }

    function test_marketBuy_buyLegNotAmmLiquid_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN); // buy leg: no AMM-liquid flag
        vm.prank(owner);
        vm.expectRevert(MarketTradeNotSupported.selector);
        _f().marketBuy(address(tradeAmm), address(usdc), 1e6, address(dai), 1e18, "");
    }

    // The protocol gate comes BEFORE the asset gates: a market order names an AMM, and anything that is
    // not one (or one the guard has retired) is refused up front, whatever the legs look like.

    function test_marketSell_throughANonAmmProtocol_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        vm.expectRevert(InvalidMarketTradeProtocol.selector);
        _f().marketSell(address(proto), address(usdc), 1e6, address(dai), 0, "");
    }

    function test_marketSell_throughADeprecatedAmm_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setDeprecated(address(tradeAmm), true);
        vm.prank(owner);
        vm.expectRevert(Deprecated.selector);
        _f().marketSell(address(tradeAmm), address(usdc), 1e6, address(dai), 0, "");
    }

    function test_marketBuy_throughANonAmmProtocol_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        vm.expectRevert(InvalidMarketTradeProtocol.selector);
        _f().marketBuy(address(proto), address(usdc), 1e6, address(dai), 1e18, "");
    }

    function test_marketBuy_throughADeprecatedAmm_reverts() public {
        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setDeprecated(address(tradeAmm), true);
        vm.prank(owner);
        vm.expectRevert(Deprecated.selector);
        _f().marketBuy(address(tradeAmm), address(usdc), 1e6, address(dai), 1e18, "");
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
        _f().enableAllowlist();
        assertTrue(_f().allowlistEnabled(), "on the moment it is asked for");
        assertFalse(_f().isAssetAllowed(address(usdc)), "and nothing is named yet");
        vm.stopPrank();
    }

    function test_underTheAllowlistOnlyNamedThingsAreReachable() public {
        vm.startPrank(owner);
        _f().enableAllowlist();
        _f().updateAssets(_one(address(usdc)), _none());
        _f().updateProtocols(_one(address(proto)), _none());
        vm.stopPrank();

        assertTrue(_f().isAssetAllowed(address(usdc)), "named");
        assertFalse(_f().isAssetAllowed(address(dai)), "not named");
        assertTrue(_f().isProtocolAllowed(address(proto)), "named");
        assertFalse(_f().isProtocolAllowed(address(amm)), "not named");
    }

    function test_theAllowlistCannotNameSomethingTheGuardRejects() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);
        vm.startPrank(owner);
        _f().enableAllowlist();
        vm.expectRevert(NotRegistered.selector);
        _f().updateAssets(_one(address(rnd)), _none());
        vm.stopPrank();
    }

    function test_theAllowlistCannotNameAProtocolTheGuardRejects() public {
        vm.startPrank(owner);
        _f().enableAllowlist();
        vm.expectRevert(NotRegistered.selector);
        _f().updateProtocols(_one(makeAddr("nowhere")), _none());
        vm.stopPrank();
    }

    function test_removingAnAssetFromTheAllowlistClosesIt() public {
        vm.startPrank(owner);
        _f().enableAllowlist();
        _f().updateAssets(_one(address(usdc)), _none());
        _f().updateAssets(_none(), _one(address(usdc)));
        vm.stopPrank();
        assertFalse(_f().isAssetAllowed(address(usdc)), "no longer named");
    }

    function test_removingAProtocolFromTheAllowlistClosesIt() public {
        vm.startPrank(owner);
        _f().enableAllowlist();
        _f().updateProtocols(_one(address(proto)), _none());
        _f().updateProtocols(_none(), _one(address(proto)));
        vm.stopPrank();
        assertFalse(_f().isProtocolAllowed(address(proto)), "no longer named");
    }

    function test_anUnnamedAssetCannotBeUsedForLiquidityWhileTheAllowlistIsOn() public {
        vm.startPrank(owner);
        _f().enableAllowlist();
        _f().updateProtocols(_one(address(amm)), _none());
        _f().updateAssets(_one(address(usdc)), _none());

        vm.expectRevert(NotRegistered.selector);
        _f().addLiquidity(address(amm), address(usdc), 1e6, address(dai), 1e18, "");
        vm.stopPrank();
    }

    function test_disablingTheAllowlistWaitsOutTheTimelockThenLapses() public {
        vm.startPrank(owner);
        vault.updatePaymentRisk(
            IBittyV1Owner.PaymentRisk({
                maxSendValue: UNCHANGED,
                maxSendInterval: UNCHANGED,
                newPaymentProtection: UNCHANGED,
                changeTimelock: 2 days
            })
        );
        _f().enableAllowlist();
        vault.disableAllowlist();
        assertTrue(_f().allowlistEnabled(), "still on while the timelock runs");
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        assertFalse(_f().allowlistEnabled(), "and off once it matures");
    }

    /// The matured pending-disable is settled lazily, on the first call that actually reads it.
    function test_theLapsedAllowlistIsSettledOnTheNextWrite() public {
        vm.startPrank(owner);
        vault.updatePaymentRisk(
            IBittyV1Owner.PaymentRisk({
                maxSendValue: UNCHANGED,
                maxSendInterval: UNCHANGED,
                newPaymentProtection: UNCHANGED,
                changeTimelock: 2 days
            })
        );
        _f().enableAllowlist();
        vault.disableAllowlist();
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        _f().deposit(address(proto), address(usdc), 10e6);
        assertFalse(_f().allowlistEnabled(), "the deposit went through and cleared the flag");
    }

    function test_disablingAnAllowlistThatIsAlreadyOffIsANoOp() public {
        vm.prank(owner);
        vault.disableAllowlist();
        assertFalse(_f().allowlistEnabled());
    }

    function test_reEnablingClearsAPendingDisable() public {
        vm.startPrank(owner);
        vault.updatePaymentRisk(
            IBittyV1Owner.PaymentRisk({
                maxSendValue: UNCHANGED,
                maxSendInterval: UNCHANGED,
                newPaymentProtection: UNCHANGED,
                changeTimelock: 2 days
            })
        );
        _f().enableAllowlist();
        vault.disableAllowlist();
        _f().enableAllowlist();
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        assertTrue(_f().allowlistEnabled(), "the scheduled loosening was cancelled");
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

    // ── AMM argument handling ─────────────────────────────────────────────────

    function test_ammCallsOnANeverUsedProtocolAreRefused() public {
        vm.startPrank(owner);
        vm.expectRevert(InvalidMarketMakerProtocol.selector);
        _f().removeLiquidity(address(amm), "");

        vm.expectRevert(InvalidMarketMakerProtocol.selector);
        _f().decreaseLiquidity(address(amm), "");

        vm.expectRevert(InvalidMarketMakerProtocol.selector);
        _f().claimAMMFees(address(amm), "");
        vm.stopPrank();
    }

    // Liquidity is dispatched by the market-maker interface, not a category: a registered protocol that
    // isn't a maker (here a lending adapter, with no addLiquidity) is rejected by the interface call
    // itself — it reverts with no matching function rather than a category error.
    function test_aNonAmmProtocolCannotProvideLiquidity() public {
        vm.prank(owner);
        vm.expectRevert(); // no addLiquidity on a lending adapter
        _f().addLiquidity(address(proto), address(usdc), 1e6, address(dai), 1e18, "");
    }

    function test_readingLiquiditiesWithRaggedArraysIsRefused() public {
        address[] memory amms = new address[](2);
        amms[0] = address(amm);
        amms[1] = address(amm);
        vm.expectRevert(ArrayLengthMismatch.selector);
        _f().getLiquidities(amms, new bytes[](1));
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
        NFTAwareAMM nftAmm = new NFTAwareAMM(address(nft));
        guard.setProtocol(address(nftAmm), MARKET_MAKER_ID);

        vm.prank(owner);
        _f().addLiquidity(address(nftAmm), address(usdc), 1e6, address(dai), 1e18, "");

        address clone = _f().getClone(address(nftAmm));
        assertTrue(nft.isApprovedForAll(address(vault), clone), "the clone can move the position NFT");
    }

    function test_theApprovalIsNotGrantedTwice() public {
        PositionNFT nft = new PositionNFT();
        NFTAwareAMM nftAmm = new NFTAwareAMM(address(nft));
        guard.setProtocol(address(nftAmm), MARKET_MAKER_ID);

        vm.startPrank(owner);
        _f().addLiquidity(address(nftAmm), address(usdc), 1e6, address(dai), 1e18, "");
        _f().removeLiquidity(address(nftAmm), "");
        vm.stopPrank();

        address clone = _f().getClone(address(nftAmm));
        assertTrue(nft.isApprovedForAll(address(vault), clone), "still approved, and not re-granted");
    }

    /// A "position NFT" that is not a contract cannot be probed; the vault skips it rather than reverting.
    function test_anUnprobeableNftIsSkippedNotFatal() public {
        SilentNFTAMM oddAmm = new SilentNFTAMM(makeAddr("notAContract"));
        guard.setProtocol(address(oddAmm), MARKET_MAKER_ID);

        vm.prank(owner);
        _f().addLiquidity(address(oddAmm), address(usdc), 1e6, address(dai), 1e18, "");
        assertTrue(_f().getClone(address(oddAmm)) != address(0), "liquidity still went in");
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
        NFTAwareAMM nftAmm = new NFTAwareAMM(address(nft));
        guard.setProtocol(address(nftAmm), MARKET_MAKER_ID);

        vm.startPrank(owner);
        _f().addLiquidity(address(nftAmm), address(usdc), 1e6, address(dai), 1e18, "");
        _f().decreaseLiquidity(address(nftAmm), "");
        _f().claimAMMFees(address(nftAmm), "");
        vm.stopPrank();

        assertTrue(nft.isApprovedForAll(address(vault), _f().getClone(address(nftAmm))), "still approved");
    }

    /**
     * With the allowlist OFF, the guard is still the floor. A token nobody registered is refused even
     * though the owner named no local restrictions at all — "allowlist off" means "fall back to Bitty's
     * curation", never "anything goes".
     */
    function test_anUnregisteredTokenCannotBecomeLiquidityEvenWithTheAllowlistOff() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);
        rnd.mint(address(vault), 100e18);
        assertFalse(_f().allowlistEnabled(), "no local narrowing at all");

        vm.prank(owner);
        vm.expectRevert(NotRegistered.selector);
        _f().addLiquidity(address(amm), address(rnd), 1e18, address(dai), 1e18, "");
    }

    function test_anUnregisteredSecondTokenIsCaughtToo() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);
        rnd.mint(address(vault), 100e18);

        vm.prank(owner);
        vm.expectRevert(NotRegistered.selector);
        _f().addLiquidity(address(amm), address(usdc), 1e6, address(rnd), 1e18, "");
    }

    // ── the route itself, not just the two ends of it ─────────────────────────
    //
    // Both ends of a market swap were checked — registered, allowed, AMM-liquid — and the road
    // between them was whatever the caller wrote. So a key that may TRADE could sell the vault's
    // balance along `USDC → JUNK → DAI` through pools it was the only liquidity provider in, and
    // collect the proceeds by withdrawing its own liquidity. {RouteGuard} walks the route and holds
    // every asset on it to the vault's own allow list.

    /// An intermediate token nobody registered is refused, in a packed v3 path.
    function test_marketSell_refusesAnUnregisteredHop() public {
        _bothLegsLiquid();
        MockERC20 junk = new MockERC20("Junk", "JUNK", 18);
        vm.prank(owner);
        vm.expectRevert(NotRegistered.selector);
        _f()
            .marketSell(
                address(tradeAmm),
                address(usdc),
                1e6,
                address(dai),
                0,
                _v3Path(address(usdc), address(junk), address(dai))
            );
    }

    /// Registered on the guard is not enough while the vault keeps its own list.
    function test_marketSell_refusesAHopOffTheVaultsOwnList() public {
        _bothLegsLiquid();
        MockERC20 mid = new MockERC20("Mid", "MID", 18);
        guard.setAsset(address(mid), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);

        vm.startPrank(owner);
        _f().enableAllowlist();
        _f().updateAssets(_one(address(usdc)), _none());
        _f().updateAssets(_one(address(dai)), _none());
        _f().updateProtocols(_one(address(tradeAmm)), _none());
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(NotRegistered.selector);
        _f()
            .marketSell(
                address(tradeAmm),
                address(usdc),
                1e6,
                address(dai),
                0,
                _v3Path(address(usdc), address(mid), address(dai))
            );
    }

    /// A hop through an asset the vault does hold is fine — the check is the allow list, not the hop count.
    function test_marketSell_allowsAHopThroughAnAllowedAsset() public {
        _bothLegsLiquid();
        MockERC20 mid = new MockERC20("Mid", "MID", 18);
        guard.setAsset(address(mid), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        vm.prank(owner);
        _f()
            .marketSell(
                address(tradeAmm),
                address(usdc),
                1e6,
                address(dai),
                0,
                _v3Path(address(usdc), address(mid), address(dai))
            );
        assertEq(usdc.allowance(address(vault), _f().getClone(address(tradeAmm))), type(uint256).max);
    }

    /// The same check inside a Universal route's own v3 command.
    function test_marketSell_refusesAnUnregisteredHopInsideAUniversalRoute() public {
        _bothLegsLiquid();
        MockERC20 junk = new MockERC20("Junk", "JUNK", 18);
        bytes memory route =
            _universal(0x00, _v3SwapIn(address(1), _v3Path(address(usdc), address(junk), address(dai))));
        vm.prank(owner);
        vm.expectRevert(NotRegistered.selector);
        _f().marketSell(address(tradeAmm), address(usdc), 1e6, address(dai), 0, route);
    }

    /// The output has to come back to the adapter. A route that pays a stranger is refused outright.
    function test_marketSell_refusesARouteThatPaysSomeoneElse() public {
        _bothLegsLiquid();
        address thief = makeAddr("thief");
        bytes memory route = _universal(0x00, _v3SwapIn(thief, _v3Path(address(usdc), address(dai))));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RouteRecipientNotAllowed.selector, thief));
        _f().marketSell(address(tradeAmm), address(usdc), 1e6, address(dai), 0, route);
    }

    /**
     * A command this library cannot read is refused rather than relayed.
     *
     * 0x0e is one of the router's transfer commands: it moves a token to an address of the caller's
     * choosing, which is value leaving by a door nothing here checks. Anything not in the known set
     * lands in the same place.
     */
    function test_marketSell_refusesAnUnknownRouterCommand() public {
        _bothLegsLiquid();
        bytes memory route = _universal(0x0e, abi.encode(address(usdc), makeAddr("thief"), uint256(1e6)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RouteCommandNotAllowed.selector, uint8(0x0e)));
        _f().marketSell(address(tradeAmm), address(usdc), 1e6, address(dai), 0, route);
    }

    /// Nor one that is allowed to fail silently: 0x80 is the router's "may revert" flag.
    function test_marketSell_refusesACommandMarkedMayRevert() public {
        _bothLegsLiquid();
        bytes memory route = _universal(0x80, _v3SwapIn(address(1), _v3Path(address(usdc), address(dai))));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RouteCommandNotAllowed.selector, uint8(0x80)));
        _f().marketSell(address(tradeAmm), address(usdc), 1e6, address(dai), 0, route);
    }

    /// An empty or truncated path is malformed: the adapter would read a token out of the next bytes.
    function test_marketSell_refusesAMalformedPath() public {
        _bothLegsLiquid();
        vm.prank(owner);
        vm.expectRevert(RouteMalformed.selector);
        _f().marketSell(address(tradeAmm), address(usdc), 1e6, address(dai), 0, "");
    }

    /// A hooked v4 pool runs its author's code inside the vault's transaction. Refused.
    function test_marketSell_refusesAHookedV4Pool() public {
        _bothLegsLiquid();
        address hook = makeAddr("hook");
        bytes memory params = abi.encode(
            RouteGuardV4Single({
                poolKey: RouteGuardV4Key({
                    currency0: address(usdc), currency1: address(dai), fee: 500, tickSpacing: 10, hooks: hook
                }),
                zeroForOne: true,
                amountIn: 1e6,
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        bytes[] memory v4Params = new bytes[](1);
        v4Params[0] = params;
        bytes memory route = _universal(0x10, abi.encode(abi.encodePacked(bytes1(uint8(0x06))), v4Params));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RouteHookNotAllowed.selector, hook));
        _f().marketSell(address(tradeAmm), address(usdc), 1e6, address(dai), 0, route);
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
        _f().marketSell(address(tradeAmm), address(usdc), 1e6, address(dai), 0, _v3Path(address(usdc), address(dai)));

        vm.prank(manager);
        vm.expectRevert();
        _f().marketBuy(address(tradeAmm), address(usdc), 1e6, address(dai), 1e18, _v3Path(address(dai), address(usdc)));
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
        assertEq(_f().assetManagerPermissions(), PERM_YIELD | PERM_INTENT, "the mask the owner passed");

        vm.prank(owner);
        _f().setAssetManager(manager, 0, 0);
        assertEq(_f().assetManagerPermissions(), 0, "and zero grants nothing");
    }

    /// Granted by name, the manager trades at market like the owner does.
    function test_aManagerGrantedMarketTradeMayTradeAtMarket() public {
        _bothLegsLiquid();
        address manager = makeAddr("manager");
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_MARKET_TRADE);

        vm.prank(manager);
        _f().marketSell(address(tradeAmm), address(usdc), 1e6, address(dai), 0, _v3Path(address(usdc), address(dai)));
        assertEq(usdc.allowance(address(vault), _f().getClone(address(tradeAmm))), type(uint256).max);
    }

    /// And a grant for one job is not a grant for another.
    function test_aManagerGrantedOnlyMarketTradeCannotProvideLiquidity() public {
        address manager = makeAddr("manager");
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_MARKET_TRADE);

        vm.prank(manager);
        vm.expectRevert();
        _f().addLiquidity(address(amm), address(usdc), 1e6, address(dai), 1e18, "");
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
        assertEq(_f().assetManagerPermissions(), PERM_YIELD | PERM_SUPPLY);

        // Narrowing is self-restriction: it lands even with a timelock set, which this vault has not.
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_YIELD);
        assertEq(_f().assetManagerPermissions(), PERM_YIELD, "narrowing took effect at once");

        // Widening with no timelock configured also lands at once — the queue is what a timelock
        // buys, and {AssetManager} covers the queued path for the grant as a whole.
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_YIELD | PERM_MARKET_TRADE);
        assertEq(_f().assetManagerPermissions(), PERM_YIELD | PERM_MARKET_TRADE, "widening, no timelock");
    }
}
