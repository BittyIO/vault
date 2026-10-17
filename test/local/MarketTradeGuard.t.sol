// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN, ASSET_CRYPTO, ASSET_AMM_LIQUID} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockMarketProtocol} from "../helpers/MockMarketProtocol.sol";
import {MARKET_TRADE_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {PaymentExceedsPeriodLimit, PendingChanges} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    MarketTradeNotSupported,
    MarketTradePriceTooLow,
    MarketTradeExceedsDailyLossAllowance,
    PriceFeedMissing,
    PriceStale,
    SequencerDown
} from "../../src/interfaces/IBittyV1DeFi.sol";
import {BITTY_GUARD, PERM_MARKET_TRADE} from "../../src/logic/Constants.sol";

interface ITrade {
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
}

/**
 * @dev A market that fills at whatever price the caller wrote into `path` — which is exactly what a
 *      route through a pool the caller set up amounts to. `swap` takes the whole `sellAmount` and pays
 *      `abi.decode(path, (uint256))` of the bought token; `swapExactOut` takes that much of the sold
 *      token and pays `buyAmount`.
 */
contract FillingMarket is MockMarketProtocol {
    function swap(bytes memory data, address recipient) external payable override {
        (address sellToken, uint256 sellAmount, address buyToken,, bytes memory path) =
            abi.decode(data, (address, uint256, address, uint256, bytes));
        IERC20(sellToken).transferFrom(msg.sender, address(this), sellAmount);
        MockERC20(buyToken).mint(recipient, abi.decode(path, (uint256)));
    }

    function swapExactOut(bytes memory data, address recipient) external override {
        (address sellToken,, address buyToken, uint256 buyAmount, bytes memory path) =
            abi.decode(data, (address, uint256, address, uint256, bytes));
        IERC20(sellToken).transferFrom(msg.sender, address(this), abi.decode(path, (uint256)));
        MockERC20(buyToken).mint(recipient, buyAmount);
    }
}

/**
 * @dev Answers Chainlink's AggregatorV3Interface with whatever the test sets.
 */
contract MockFeed {
    uint8 public decimals = 8;

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }

    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;

    function set(int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, updatedAt, 1);
    }
}

/**
 * The case this guard exists for: a leaked key that sells the vault's assets into a pool it set up
 * itself. Every route is the caller's to choose, so a protected vault judges the trade by what actually
 * left and arrived, at oracle value — and caps what trades may lose per day. An owner who leaves the
 * allowance at 0, the default, opts out of all of it.
 */
contract MarketTradeGuardTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 dai;
    MockERC20 weth;
    FillingMarket market;
    MockFeed wethFeed;

    address owner = makeAddr("owner");
    uint256 constant UNCHANGED = type(uint256).max;
    uint256 constant HEARTBEAT = 1 hours;
    uint256 constant ROOMY = 1_000_000; // a daily allowance the price-check tests never reach

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        bytes memory init = abi.encodeCall(
            BittyV1Vault.initialize, (owner, makeAddr("gasWrapped"), false, address(0), 0, new bytes[](0))
        );
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        market = new FillingMarket();

        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(weth), ASSET_CRYPTO | ASSET_AMM_LIQUID);
        guard.setProtocol(address(market), MARKET_TRADE_ID);

        wethFeed = new MockFeed();
        wethFeed.set(2_000e8, block.timestamp, block.timestamp);
        _registerFeed(address(weth), address(wethFeed), HEARTBEAT);

        weth.mint(address(vault), 100e18);
        usdc.mint(address(vault), 1_000_000e6);
        dai.mint(address(vault), 1_000_000e18);

        _risk(UNCHANGED, ROOMY);
    }

    function _registerFeed(address asset, address feed, uint256 maxAge) internal {
        _registerFeed(asset, feed, maxAge, address(0));
    }

    function _registerFeed(address asset, address feed, uint256 maxAge, address quote) internal {
        guard.setPriceFeed(asset, feed, uint32(maxAge), quote);
    }

    function _token(string memory symbol, uint8 decimals, uint256 vaultBalance) internal returns (MockERC20 t) {
        t = new MockERC20(symbol, symbol, decimals);
        guard.setAsset(address(t), ASSET_CRYPTO | ASSET_AMM_LIQUID);
        t.mint(address(vault), vaultBalance);
    }

    function _feed(int256 answer, uint8 decimals) internal returns (MockFeed f) {
        f = new MockFeed();
        f.setDecimals(decimals);
        f.set(answer, block.timestamp, block.timestamp);
    }

    function _sell(address sellToken, uint256 sellAmount, address buyToken, uint256 fill) internal {
        vm.prank(owner);
        ITrade(address(vault)).marketSell(address(market), sellToken, sellAmount, buyToken, 0, abi.encode(fill));
    }

    function _buy(address sellToken, uint256 maxIn, address buyToken, uint256 buyAmount, uint256 spent) internal {
        vm.prank(owner);
        ITrade(address(vault)).marketBuy(address(market), sellToken, maxIn, buyToken, buyAmount, abi.encode(spent));
    }

    function _risk(uint256 timelock, uint256 marketTradeDailyLossAllowance) internal {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(timelock, UNCHANGED, marketTradeDailyLossAllowance));
    }

    function _sendCap(uint256 sendDailyAllowance) internal {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(UNCHANGED, sendDailyAllowance, UNCHANGED));
    }

    function _send(uint256 usdcAmount) internal {
        vm.prank(owner);
        vault.send(makeAddr("payee"), address(usdc), usdcAmount, new address[](0), new uint256[](0));
    }

    // ── price check ─────────────────────────────────────────────────────────────────────────────

    function test_aFairTradeGoesThrough() public {
        _sell(address(weth), 1e18, address(usdc), 1_990e6);
        assertEq(weth.balanceOf(address(vault)), 99e18);
        assertEq(usdc.balanceOf(address(vault)), 1_001_990e6);
    }

    /**
     * The attack: everything into the caller's own pool for one wei. `buyAmountMin` is 0 and the
     * route is theirs, so nothing but the oracle stands in the way.
     */
    function test_sellingIntoARiggedPoolReverts() public {
        vm.expectRevert(MarketTradePriceTooLow.selector);
        _sell(address(weth), 100e18, address(usdc), 1);
    }

    function test_fivePercentUnderOracleIsTheEdge() public {
        _sell(address(weth), 1e18, address(usdc), 1_900e6);

        vm.expectRevert(MarketTradePriceTooLow.selector);
        _sell(address(weth), 1e18, address(usdc), 1_900e6 - 1);
    }

    /// Buying nothing is the rigged pool at its limit: whatever was sold, it came out at zero.
    function test_aTradeThatBuysNothingReverts() public {
        vm.expectRevert(MarketTradePriceTooLow.selector);
        _sell(address(weth), 1e18, address(usdc), 0);
    }

    /// A route that took nothing has nothing to judge or charge, even though it bought.
    function test_aTradeThatSellsNothingIsNotCharged() public {
        _buy(address(weth), 1e18, address(usdc), 1_000e6, 0);
        assertEq(weth.balanceOf(address(vault)), 100e18, "nothing sold");
        assertEq(usdc.balanceOf(address(vault)), 1_001_000e6, "and the fill kept");
    }

    function test_marketBuyIsJudgedOnWhatItActuallySpent() public {
        vm.expectRevert(MarketTradePriceTooLow.selector);
        _buy(address(usdc), 1_000_000e6, address(weth), 1e18, 1_000_000e6);

        _buy(address(usdc), 1_000_000e6, address(weth), 1e18, 2_010e6);
        assertEq(weth.balanceOf(address(vault)), 101e18);
    }

    /**
     * Two stablecoins are a dollar each, the rule the send allowance already counts by — no feed.
     */
    function test_stableToStableNeedsNoFeed() public {
        _sell(address(usdc), 1_000e6, address(dai), 999e18);

        vm.expectRevert(MarketTradePriceTooLow.selector);
        _sell(address(usdc), 1_000e6, address(dai), 900e18);
    }

    function test_anAssetWithNoFeedCannotBeSold() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        guard.setAsset(address(other), ASSET_CRYPTO | ASSET_AMM_LIQUID);
        other.mint(address(vault), 1e18);

        vm.expectRevert(abi.encodeWithSelector(PriceFeedMissing.selector, address(other)));
        _sell(address(other), 1e18, address(usdc), 1_000e6);
    }

    function test_aStalePriceStopsTheTrade() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);

        vm.expectRevert(abi.encodeWithSelector(PriceStale.selector, address(weth)));
        _sell(address(weth), 1e18, address(usdc), 2_000e6);
    }

    function test_aNonPositiveAnswerStopsTheTrade() public {
        wethFeed.set(0, block.timestamp, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(PriceStale.selector, address(weth)));
        _sell(address(weth), 1e18, address(usdc), 2_000e6);
    }

    function test_theSameTokenOnBothLegsIsRefused() public {
        vm.expectRevert(MarketTradeNotSupported.selector);
        _sell(address(usdc), 1_000e6, address(usdc), 1_000e6);
    }

    // ── L2 sequencer ────────────────────────────────────────────────────────────────────────────

    function test_aDownSequencerStopsPricedTrades() public {
        MockFeed uptime = new MockFeed();
        uptime.set(1, block.timestamp - 2 hours, block.timestamp);
        guard.setSequencerUptimeFeed(address(uptime));

        vm.expectRevert(SequencerDown.selector);
        _sell(address(weth), 1e18, address(usdc), 2_000e6);

        // A stable-to-stable trade reads no feed, so it does not need the sequencer either.
        _sell(address(usdc), 1_000e6, address(dai), 1_000e18);
    }

    function test_aSequencerJustBackIsNotTrustedUntilTheGracePeriodEnds() public {
        MockFeed uptime = new MockFeed();
        uptime.set(0, block.timestamp - 30 minutes, block.timestamp);
        guard.setSequencerUptimeFeed(address(uptime));

        vm.expectRevert(SequencerDown.selector);
        _sell(address(weth), 1e18, address(usdc), 2_000e6);

        vm.warp(block.timestamp + 31 minutes);
        wethFeed.set(2_000e8, block.timestamp, block.timestamp);
        _sell(address(weth), 1e18, address(usdc), 2_000e6);
    }

    // ── second feed ─────────────────────────────────────────────────────────────────────────────

    /**
     * LDO has no USD feed, only LDO / ETH: priced as that times WETH's own USD feed.
     */
    function test_aFeedQuotedInAnotherAssetIsChainedThroughIt() public {
        MockERC20 ldo = _token("LDO", 18, 1_000e18);
        _registerFeed(address(ldo), address(_feed(0.0005e18, 18)), HEARTBEAT, address(weth)); // $1

        _sell(address(ldo), 1_000e18, address(usdc), 950e6);
        assertEq(ldo.balanceOf(address(vault)), 0);

        ldo.mint(address(vault), 1_000e18);
        vm.expectRevert(MarketTradePriceTooLow.selector);
        _sell(address(ldo), 1_000e18, address(usdc), 950e6 - 1);
    }

    /**
     * WBTC / BTC × BTC / USD, with BTC — which no registered asset stands for — configured under
     * Chainlink's placeholder address.
     */
    function test_aQuoteCanBeAPlaceholderForANonToken() public {
        address btc = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
        MockERC20 wbtc = _token("WBTC", 8, 1e8);
        _registerFeed(btc, address(_feed(60_000e8, 8)), HEARTBEAT);
        _registerFeed(address(wbtc), address(_feed(0.99e8, 8)), HEARTBEAT, btc); // $59,400

        vm.expectRevert(MarketTradePriceTooLow.selector);
        _sell(address(wbtc), 1e8, address(usdc), 56_430e6 - 1);
        _sell(address(wbtc), 1e8, address(usdc), 56_430e6);
    }

    function test_aQuoteWithNoFeedOfItsOwnFailsClosed() public {
        MockERC20 ldo = _token("LDO", 18, 1_000e18);
        MockERC20 eth2 = _token("ETH2", 18, 0);
        _registerFeed(address(ldo), address(_feed(0.0005e18, 18)), HEARTBEAT, address(eth2));

        vm.expectRevert(abi.encodeWithSelector(PriceFeedMissing.selector, address(eth2)));
        _sell(address(ldo), 1_000e18, address(usdc), 1_000e6);
    }

    function test_aStaleQuoteStopsTheTrade() public {
        MockERC20 ldo = _token("LDO", 18, 1_000e18);
        vm.warp(block.timestamp + HEARTBEAT + 1);
        _registerFeed(address(ldo), address(_feed(0.0005e18, 18)), HEARTBEAT, address(weth));

        vm.expectRevert(abi.encodeWithSelector(PriceStale.selector, address(weth)));
        _sell(address(ldo), 1_000e18, address(usdc), 1_000e6);
    }

    /**
     * One hop only: a quote that is itself quoted would let config chain without bound.
     */
    function test_aQuoteThatIsItselfQuotedIsRefused() public {
        MockERC20 ldo = _token("LDO", 18, 1_000e18);
        MockERC20 steth = _token("stETH", 18, 0);
        _registerFeed(address(steth), address(_feed(1e18, 18)), HEARTBEAT, address(weth));
        _registerFeed(address(ldo), address(_feed(0.0005e18, 18)), HEARTBEAT, address(steth));

        vm.expectRevert(abi.encodeWithSelector(PriceFeedMissing.selector, address(steth)));
        _sell(address(ldo), 1_000e18, address(usdc), 1_000e6);
    }

    // ── daily loss allowance ───────────────────────────────────────────────────────────────────

    /**
     * 5% a trade is still all of it in about 90 trades through the caller's own pool. The day's
     * allowance is what stops that, however the drain is split.
     */
    function test_theAllowanceStopsAGrind() public {
        _risk(UNCHANGED, 100);

        uint256 trades;
        while (true) {
            vm.prank(owner);
            try ITrade(address(vault))
                .marketSell(address(market), address(weth), 1e18, address(usdc), 0, abi.encode(1_940e6)) {
                ++trades;
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), MarketTradeExceedsDailyLossAllowance.selector);
                break;
            }
        }
        assertEq(trades, 1, "$60 lost, and the next $60 would pass $100");
        assertEq(weth.balanceOf(address(vault)), 99e18);
    }

    function test_theAllowanceRunsOverARollingDay() public {
        _risk(UNCHANGED, 100);

        _sell(address(weth), 1e18, address(usdc), 1_950e6); // $50
        _sell(address(weth), 1e18, address(usdc), 1_950e6); // $100: the whole allowance
        vm.expectRevert(MarketTradeExceedsDailyLossAllowance.selector);
        _sell(address(weth), 1e18, address(usdc), 1_999e6);

        _sell(address(weth), 1e18, address(usdc), 2_000e6); // at oracle value: nothing to charge

        vm.warp(block.timestamp + 1 days);
        wethFeed.set(2_000e8, block.timestamp, block.timestamp);
        _sell(address(weth), 1e18, address(usdc), 1_950e6);
    }

    function test_aTradeThatComesOutAheadCreditsNothingBack() public {
        _risk(UNCHANGED, 100);

        _sell(address(weth), 1e18, address(usdc), 1_900e6 + 100e6 + 100e6); // $100 ahead
        _sell(address(weth), 1e18, address(usdc), 1_950e6); // $50
        vm.expectRevert(MarketTradeExceedsDailyLossAllowance.selector);
        _sell(address(weth), 1e18, address(usdc), 1_949e6); // $51 more is past $100, gain or no gain
    }

    /**
     * `sellAmountMax` is what the caller was willing to spend; the allowance is charged with what
     * actually left, less what it bought.
     */
    function test_marketBuyChargesWhatItActuallyLost() public {
        _risk(UNCHANGED, 15);

        _buy(address(usdc), 100_000e6, address(dai), 1_000e18, 1_010e6); // $10
        vm.expectRevert(MarketTradeExceedsDailyLossAllowance.selector);
        _buy(address(usdc), 100_000e6, address(dai), 1_000e18, 1_010e6);
    }

    function test_raisingTheAllowanceWaitsOutTheTimelock() public {
        _risk(2 days, 50);
        _risk(UNCHANGED, 10_000);

        (,, uint64 allowance) = vault.riskSettings();
        assertEq(allowance, 50, "a loosening does not apply at once");
        PendingChanges memory p = vault.pendingChanges();
        assertEq(p.marketTradeDailyLossAllowance, 10_000);
        assertEq(p.marketTradeDailyLossAllowanceAt, uint64(block.timestamp + 2 days));

        vm.expectRevert(MarketTradeExceedsDailyLossAllowance.selector);
        _sell(address(weth), 1e18, address(usdc), 1_940e6);

        vm.warp(block.timestamp + 2 days);
        wethFeed.set(2_000e8, block.timestamp, block.timestamp);
        _sell(address(weth), 1e18, address(usdc), 1_940e6);
    }

    /**
     * Turning protection off is the biggest loosening there is, so a leaked key waits it out too.
     */
    function test_turningProtectionOffWaitsOutTheTimelock() public {
        _risk(2 days, 1_000);
        _risk(UNCHANGED, 0);

        (,, uint64 allowance) = vault.riskSettings();
        assertEq(allowance, 1_000, "0 is unprotected, so it waits like any raise");
        vm.expectRevert(MarketTradePriceTooLow.selector);
        _sell(address(weth), 100e18, address(usdc), 1);
    }

    /**
     * The two ceilings are kept apart: a day of trading never uses up what may be sent, and a day of
     * sending never uses up what trades may lose.
     */
    function test_sendsAndTradeLossesAreCountedApart() public {
        _risk(UNCHANGED, 100);
        _sendCap(100);

        _send(100e6); // the whole send allowance
        _sell(address(weth), 1e18, address(usdc), 1_950e6); // $50 lost: the trade allowance is untouched by it

        vm.expectRevert(PaymentExceedsPeriodLimit.selector);
        _send(1);
        _sell(address(weth), 1e18, address(usdc), 1_950e6); // and $100 of losses is still within its own
        vm.expectRevert(MarketTradeExceedsDailyLossAllowance.selector);
        _sell(address(weth), 1e18, address(usdc), 1_999e6);
    }

    /**
     * A leaked asset-manager key is the same drain as a leaked owner key, so its trades count too.
     */
    function test_anAssetManagersTradeLossesCountAgainstTheAllowance() public {
        _risk(UNCHANGED, 100);
        address manager = makeAddr("manager");
        vm.prank(owner);
        BittyV1VaultDeFiFacet(payable(address(vault)))
            .setAssetManager(manager, uint64(block.timestamp + 365 days), PERM_MARKET_TRADE);

        vm.prank(manager);
        ITrade(address(vault)).marketSell(address(market), address(weth), 1e18, address(usdc), 0, abi.encode(1_940e6));
        vm.expectRevert(MarketTradeExceedsDailyLossAllowance.selector);
        _sell(address(weth), 1e18, address(usdc), 1_940e6); // $60 + $60 is past $100, whoever traded
    }

    function test_aLockDropsAWaitingRaise() public {
        _risk(2 days, 1_000);
        _risk(UNCHANGED, 10_000);

        vm.prank(owner);
        vault.emergencyLock();

        vm.warp(block.timestamp + 2 days);
        (,, uint64 allowance) = vault.riskSettings();
        assertEq(allowance, 1_000, "the raise was queued before the lock and died with it");
    }

    // ── unprotected ─────────────────────────────────────────────────────────────────────────────

    /**
     * At 0 the owner has opted out: the trade reads no price, so it takes any fill the caller's
     * minimum allows — the rigged pool included — and needs no feed, fresh or otherwise.
     */
    function test_anUnprotectedVaultTradesAtAnyPrice() public {
        _risk(UNCHANGED, 0);

        _sell(address(weth), 50e18, address(usdc), 1);

        MockERC20 other = _token("OTH", 18, 1e18);
        _sell(address(other), 1e18, address(usdc), 1);

        vm.warp(block.timestamp + HEARTBEAT + 1);
        _sell(address(weth), 50e18, address(usdc), 1);
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    function test_anUnprotectedVaultStillTradesOnlyAmmLiquidAssets() public {
        _risk(UNCHANGED, 0);
        MockERC20 illiquid = new MockERC20("ILQ", "ILQ", 18);
        guard.setAsset(address(illiquid), ASSET_CRYPTO);
        illiquid.mint(address(vault), 1e18);

        vm.expectRevert(MarketTradeNotSupported.selector);
        _sell(address(illiquid), 1e18, address(usdc), 1);
    }

    function test_anUnprotectedVaultIgnoresTheSequencer() public {
        _risk(UNCHANGED, 0);
        MockFeed uptime = new MockFeed();
        uptime.set(1, block.timestamp - 2 hours, block.timestamp);
        guard.setSequencerUptimeFeed(address(uptime));

        _sell(address(weth), 1e18, address(usdc), 2_000e6);
    }
}
