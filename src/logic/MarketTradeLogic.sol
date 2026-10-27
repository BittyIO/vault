// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    IBittyV1Guard,
    MarketTradeInfo,
    ASSET_AMM_LIQUID,
    PROTOCOL_MARKET_TRADE
} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1MarketTradeProtocol} from "protocol-contracts/src/interfaces/IBittyV1MarketTradeProtocol.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {
    InvalidMarketTradeProtocol,
    MarketTradeNotSupported,
    MarketTradePriceTooLow,
    MarketTradeExceedsDailyLossAllowance
} from "../interfaces/IBittyV1DeFi.sol";
import {Deprecated, NotRegistered, ReentrantCall} from "../interfaces/IBittyV1Vault.sol";
import {BittyStorage, DeFiStorage, VaultStorage} from "./BittyStorage.sol";
import {DeFiLogic} from "./DeFiLogic.sol";
import {PriceLib} from "./PriceLib.sol";
import {RiskLogic} from "./RiskLogic.sol";
import {BITTY_GUARD, MAX_MARKET_TRADE_SLIPPAGE_BPS} from "./Constants.sol";

/**
 * @dev A market trade's two legs as they stood before the protocol ran. See {MarketTradeLogic-_marketLegs}.
 */
struct MarketLegs {
    address sellToken;
    address buyToken;
    uint8 sellCategory;
    uint8 buyCategory;
    uint256 sellBefore;
    uint256 buyBefore;
}

/**
 * @title MarketTradeLogic
 * @notice Market buys and sells. Every trade is held to oracle value and its shortfall charged to the
 *         owner's `marketTradeDailyLossAllowance`, which cannot be lifted — so only an asset with a
 *         price feed (or a stablecoin) can be traded at market. An allowance of 0 turns market trading
 *         off: every trade is refused before it runs, even one that would lose nothing.
 * @dev Its own library because the price and allowance checks do not fit in {DeFiLogic} under the
 *      24,576-byte code size limit. The protocol, asset and clone checks are {DeFiLogic}'s own, called
 *      as internal functions and so compiled in here: one definition, no library-to-library link.
 *      Operates on the same ERC-7201 {DeFiStorage} and {VaultStorage}.
 */
library MarketTradeLogic {
    using SafeERC20 for IERC20;

    // Set while a market trade runs — keccak256("bitty.transient.vault.marketTrade"). The trade is
    // judged by the vault's balances before and after the protocol runs, and the route is the
    // caller's: it can run the caller's code mid-swap (a token's transfer hook, a pool hook, ETH sent
    // to a contract). Anything that call could do to move those balances — unwind a position into
    // the vault, run a second trade, fill a signed intent order, wrap idle ETH — would be counted as
    // what the trade did, so a sale into the caller's own pool could pass as fair. Every vault
    // function that moves balances refuses while it is set (see {requireNotTrading}). Transient, so
    // like {PaymentCore}'s payout lock it binds nothing across an upgrade.
    bytes32 private constant _TRADING_SLOT = 0x2c5e93362f6cd886a87129ab7e35433621ed27ad98f1b17be33ee853e8647670;

    /**
     * Reverts while a market trade is running. Called by every vault function that moves balances.
     */
    function requireNotTrading() internal view {
        if (isTrading()) revert ReentrantCall();
    }

    function isTrading() internal view returns (bool trading) {
        assembly ("memory-safe") {
            trading := tload(_TRADING_SLOT)
        }
    }

    function _setTrading(bool trading) private {
        assembly ("memory-safe") {
            tstore(_TRADING_SLOT, trading)
        }
    }

    function marketSell(
        address marketTradeProtocol,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmountMin,
        bytes memory path
    ) external {
        requireNotTrading();
        _setTrading(true);
        DeFiStorage storage $ = BittyStorage.defi();
        DeFiLogic._onlyInitialized();
        uint64 lossAllowance = _lossAllowance();
        (MarketLegs memory legs, MarketTradeInfo memory info) = _marketLegs($, marketTradeProtocol, sellToken, buyToken);

        address clone = DeFiLogic._cloneProtocol($, marketTradeProtocol);
        if (sellToken != address(0) && sellAmount > 0 && IERC20(sellToken).allowance(address(this), clone) < sellAmount)
        {
            IERC20(sellToken).forceApprove(clone, type(uint256).max);
        }
        bytes memory data = abi.encode(sellToken, sellAmount, buyToken, buyAmountMin, path);
        IBittyV1MarketTradeProtocol(clone).swap{value: sellToken == address(0) ? sellAmount : 0}(data, address(this));
        _settleMarketTrade(legs, info, lossAllowance);
        _setTrading(false);
    }

    function marketBuy(
        address marketTradeProtocol,
        address sellToken,
        uint256 sellAmountMax,
        address buyToken,
        uint256 buyAmount,
        bytes memory reversedPath
    ) external {
        requireNotTrading();
        _setTrading(true);
        DeFiStorage storage $ = BittyStorage.defi();
        DeFiLogic._onlyInitialized();
        uint64 lossAllowance = _lossAllowance();
        (MarketLegs memory legs, MarketTradeInfo memory info) = _marketLegs($, marketTradeProtocol, sellToken, buyToken);

        address clone = DeFiLogic._cloneProtocol($, marketTradeProtocol);
        if (sellToken != address(0) && IERC20(sellToken).allowance(address(this), clone) < sellAmountMax) {
            IERC20(sellToken).forceApprove(clone, type(uint256).max);
        }
        bytes memory data = abi.encode(sellToken, sellAmountMax, buyToken, buyAmount, reversedPath);
        IBittyV1MarketTradeProtocol(clone).swapExactOut(data, address(this));
        _settleMarketTrade(legs, info, lossAllowance);
        _setTrading(false);
    }

    function _lossAllowance() private view returns (uint64 allowance) {
        allowance = RiskLogic.effectiveMarketTradeDailyLossAllowance(BittyStorage.vault().riskConfig);
        if (allowance == 0) revert MarketTradeExceedsDailyLossAllowance();
    }

    /**
     * @dev Everything a market trade checks before it runs, from one guard read,
     *      {IBittyV1Guard-marketTradeInfo}, which also brings the price feeds: the protocol is a live
     *      market-trade protocol and both tokens are registered, each also named on the owner's own
     *      allow list when that is on; the tokens differ — the same token on both legs would net its
     *      own sale against its own purchase and hide both — and both may trade at market. The vault's
     *      balance of each token is taken just before the protocol runs.
     */
    function _marketLegs(DeFiStorage storage $, address protocol, address sellToken, address buyToken)
        private
        view
        returns (MarketLegs memory legs, MarketTradeInfo memory info)
    {
        info = IBittyV1Guard(BITTY_GUARD).marketTradeInfo(protocol, sellToken, buyToken);
        bool ownList = BittyStorage.vault().ownAllowListActive;
        if (info.protocolCategory != PROTOCOL_MARKET_TRADE || (ownList && !$.protocols[protocol])) {
            revert InvalidMarketTradeProtocol();
        }
        if (info.protocolDeprecated) revert Deprecated();
        if (info.sellCategory == 0 || (ownList && !$.assets[sellToken])) revert NotRegistered();
        if (info.buyCategory == 0 || (ownList && !$.assets[buyToken])) revert NotRegistered();
        if (sellToken == buyToken) revert MarketTradeNotSupported();
        if (info.sellCategory & info.buyCategory & ASSET_AMM_LIQUID == 0) revert MarketTradeNotSupported();

        legs.sellToken = sellToken;
        legs.buyToken = buyToken;
        legs.sellCategory = info.sellCategory;
        legs.buyCategory = info.buyCategory;
        legs.sellBefore = _balanceOf(sellToken);
        legs.buyBefore = _balanceOf(buyToken);
    }

    /**
     * @dev What a market trade actually did, measured on the vault's own balances: never from the
     *      arguments or the protocol, since the route the protocol runs is the caller's to choose —
     *      any pool, any hop, including one the caller created and priced. A leaked key that sells
     *      into such a pool for nothing is the case this exists for.
     *
     *      The sold leg is valued rounding up and the bought leg rounding down, both at oracle value,
     *      and the trade must come out within {MAX_MARKET_TRADE_SLIPPAGE_BPS} of what it sold. What it
     *      came out short is then charged to `lossAllowance`: the 5% bounds one trade, and this bounds
     *      the day, however many trades a leaked key — the owner's or an asset manager's — splits a
     *      drain into. A trade that comes out ahead of the oracle charges nothing and credits nothing
     *      back.
     */
    function _settleMarketTrade(MarketLegs memory legs, MarketTradeInfo memory info, uint64 lossAllowance) private {
        uint256 sellAfter = _balanceOf(legs.sellToken);
        uint256 buyAfter = _balanceOf(legs.buyToken);
        uint256 sold = legs.sellBefore > sellAfter ? legs.sellBefore - sellAfter : 0;
        uint256 bought = buyAfter > legs.buyBefore ? buyAfter - legs.buyBefore : 0;
        if (sold == 0) return;

        PriceLib.requireSequencerUp(info.sequencerUptimeFeed); // zero when both legs are stablecoins
        uint256 valueIn = PriceLib.usdValue(
            legs.sellToken, legs.sellCategory, sold, Math.Rounding.Ceil, info.sellFeed, info.sellQuoteFeed
        );
        uint256 valueOut = PriceLib.usdValue(
            legs.buyToken, legs.buyCategory, bought, Math.Rounding.Floor, info.buyFeed, info.buyQuoteFeed
        );
        if (valueOut * 10_000 < valueIn * (10_000 - MAX_MARKET_TRADE_SLIPPAGE_BPS)) revert MarketTradePriceTooLow();

        if (valueOut < valueIn) _chargeMarketTradeLoss(valueIn - valueOut, lossAllowance);
    }

    /**
     * @dev The send allowance's rolling day, kept separately for what trades lose.
     */
    function _chargeMarketTradeLoss(uint256 loss, uint64 lossAllowance) private {
        VaultStorage storage v = BittyStorage.vault();
        uint64 periodStart = v.marketTradePeriodStart;
        uint256 lost = v.marketTradeLossInPeriod;
        if (periodStart == 0 || block.timestamp >= uint256(periodStart) + 1 days) {
            periodStart = uint64(block.timestamp);
            lost = 0;
        }
        lost += loss;
        if (lost > uint256(lossAllowance) * 1e18) revert MarketTradeExceedsDailyLossAllowance();
        v.marketTradePeriodStart = periodStart;
        v.marketTradeLossInPeriod = uint128(lost);
    }

    function _balanceOf(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }
}
