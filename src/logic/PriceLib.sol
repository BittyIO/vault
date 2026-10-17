// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN, PriceFeed} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {PriceFeedMissing, PriceStale, SequencerDown} from "../interfaces/IBittyV1DeFi.sol";
import {SEQUENCER_GRACE_PERIOD} from "./Constants.sol";

/**
 * @dev The slice of Chainlink's AggregatorV3Interface the vault reads.
 */
interface IChainlinkFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title PriceLib
 * @notice USD value of an asset amount, 18 decimals, for checking a market trade against a price the
 *         trade itself cannot move.
 * @dev A stablecoin is a dollar, the same rule the send allowance counts by, so a stable leg costs no
 *      feed read. Anything else is priced off the Chainlink feed the guard holds for it — handed in by
 *      the caller from the one {IBittyV1Guard-marketTradeInfo} read — times the feed of the asset that
 *      one is quoted in when it is not a USD feed. The feed's decimals and the asset's come with it,
 *      read once when the guard was configured, so a priced leg's only call is its feed's
 *      `latestRoundData`; a stablecoin's decimals are still asked of the token. Every doubt
 *      fails closed: no feed, no staleness bound, a quote that is itself quoted, a non-positive
 *      answer, an answer older than that bound, or an L2 sequencer that is down or only just back all
 *      revert, which stops trading and nothing else — sends, withdrawals and locks never read a price.
 *
 *      Internal, so it inlines into {MarketTradeLogic} — no separate deployment.
 */
library PriceLib {
    function isStable(uint8 category) internal pure returns (bool) {
        return category & ASSET_STABLE_COIN != 0;
    }

    function usdValue(
        address asset,
        uint8 category,
        uint256 amount,
        Math.Rounding rounding,
        PriceFeed memory feed,
        PriceFeed memory quoteFeed
    ) internal view returns (uint256) {
        if (amount == 0) return 0;
        if (isStable(category)) return Math.mulDiv(amount, 1e18, 10 ** _decimals(asset), rounding);

        uint256 scale = 10 ** (feed.assetDecimals != 0 ? feed.assetDecimals : _decimals(asset));
        (uint256 price, uint256 priceScale) = _feedPrice(asset, feed);
        if (feed.hasQuote) {
            if (quoteFeed.hasQuote) revert PriceFeedMissing(feed.quote);
            (uint256 quotePrice, uint256 quoteScale) = _feedPrice(feed.quote, quoteFeed);
            price *= quotePrice;
            priceScale *= quoteScale;
        }
        return Math.mulDiv(amount, price * 1e18, scale * priceScale, rounding);
    }

    /**
     * @dev One feed's answer for `asset`, checked fresh, and the power of ten it is scaled by.
     */
    function _feedPrice(address asset, PriceFeed memory feed) private view returns (uint256 price, uint256 scale) {
        if (feed.feed == address(0) || feed.maxAge == 0) revert PriceFeedMissing(asset);
        (, int256 answer,, uint256 updatedAt,) = IChainlinkFeed(feed.feed).latestRoundData();
        if (answer <= 0 || block.timestamp > updatedAt + feed.maxAge) revert PriceStale(asset);
        return (uint256(answer), 10 ** feed.decimals);
    }

    /**
     * @dev Chainlink's L2 sequencer check: answer 0 means up, and `startedAt` is when it last changed
     *      state; a zero `startedAt` is a round that has not been initialised, so it is not trusted
     *      either. A no-op for a zero `feed`: a chain with none, or a trade that read no price.
     */
    function requireSequencerUp(address feed) internal view {
        if (feed == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = IChainlinkFeed(feed).latestRoundData();
        if (answer != 0 || startedAt == 0 || block.timestamp <= startedAt + SEQUENCER_GRACE_PERIOD) {
            revert SequencerDown();
        }
    }

    function _decimals(address asset) private view returns (uint8) {
        return asset == address(0) ? 18 : IERC20Metadata(asset).decimals();
    }
}
