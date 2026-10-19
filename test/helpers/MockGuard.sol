// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN, PriceFeed, MarketTradeInfo} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";

interface IFeedDecimals {
    function decimals() external view returns (uint8);
}

/**
 * @notice A configurable stand-in for the Bitty guard, covering the subset the subaccount system reads:
 *         the timelocked implementation registry plus the asset/protocol registries. Etch it at
 *         BITTY_GUARD and drive it with the setters. Public mappings auto-generate the interface getters.
 */
contract MockGuard {
    // Keyed by category, like the guard: the two are separate registries so a sub vault cannot be
    // pointed at main-vault code.
    mapping(uint8 => mapping(address => bool)) internal _registered;
    mapping(uint8 category => address) public latestImplementation;

    function isImplementationRegisteredFor(address impl, uint8 category) external view returns (bool) {
        return _registered[category][impl];
    }

    function setLatestImpl(uint8 category, address impl) external {
        latestImplementation[category] = impl;
        _registered[category][impl] = true;
    }
    mapping(address => uint8) public assetCategory;
    mapping(address => uint8) public protocolCategory;
    mapping(address => bool) public isProtocolDeprecated;
    address[] internal _protocols;
    address[] internal _deprecated;

    function isAssetRegistered(address a) external view returns (bool) {
        return assetCategory[a] != 0;
    }

    /**
     * As in the real guard, deprecating a protocol takes it out of the registered set.
     */
    function isProtocolRegistered(address p) external view returns (bool) {
        return protocolCategory[p] != 0 && !isProtocolDeprecated[p];
    }

    function getProtocols() external view returns (address[] memory) {
        return _protocols;
    }

    function getDeprecatedProtocols() external view returns (address[] memory) {
        return _deprecated;
    }

    // ── setters ──
    function setImpl(address impl, bool ok) external {
        // Default to the main-vault category, which is what almost every test means.
        _registered[1][impl] = ok;
    }

    function setImplFor(address impl, uint8 category, bool ok) external {
        _registered[category][impl] = ok;
    }

    function setAsset(address a, uint8 cat) external {
        assetCategory[a] = cat;
    }

    function setProtocol(address p, uint8 cat) external {
        protocolCategory[p] = cat;
        _protocols.push(p);
    }

    function setDeprecated(address p, bool ok) external {
        if (isProtocolDeprecated[p] == ok) return;
        isProtocolDeprecated[p] = ok;
        if (ok) {
            _deprecated.push(p);
            return;
        }
        for (uint256 i; i < _deprecated.length; ++i) {
            if (_deprecated[i] != p) continue;
            _deprecated[i] = _deprecated[_deprecated.length - 1];
            _deprecated.pop();
            return;
        }
    }

    // ── config map (public mappings auto-generate getAddress(bytes32)/getUint(bytes32)) ──
    mapping(bytes32 => address) public getAddress;
    mapping(bytes32 => uint256) public getUint;

    function setConfigAddress(bytes32 key, address value) external {
        getAddress[key] = value;
    }

    function setConfigUint(bytes32 key, uint256 value) external {
        getUint[key] = value;
    }

    // ── price feeds and the one-call market-trade read, as the real guard answers them ──
    mapping(address => PriceFeed) internal _priceFeeds;
    address public sequencerUptimeFeed;

    function priceFeed(address asset) external view returns (PriceFeed memory) {
        return _priceFeeds[asset];
    }

    /**
     * @dev Reads the feed's decimals from the feed, as the real setter does. A zero feed clears it.
     */
    function setPriceFeed(address asset, address feed, uint32 maxAge, address quote) external {
        if (feed == address(0)) {
            delete _priceFeeds[asset];
            return;
        }
        uint8 assetDecimals = 18;
        if (asset != address(0)) {
            (bool ok, bytes memory data) = asset.staticcall(abi.encodeCall(IFeedDecimals.decimals, ()));
            assetDecimals = ok && data.length >= 32 ? abi.decode(data, (uint8)) : 0;
        }
        _priceFeeds[asset] = PriceFeed({
            feed: feed,
            maxAge: maxAge,
            decimals: IFeedDecimals(feed).decimals(),
            assetDecimals: assetDecimals,
            hasQuote: quote != address(0),
            quote: quote
        });
    }

    function setSequencerUptimeFeed(address feed) external {
        sequencerUptimeFeed = feed;
    }

    function marketTradeChecks(address protocol, address sellToken, address buyToken)
        external
        view
        returns (uint8, bool, uint8, uint8)
    {
        return (
            protocolCategory[protocol],
            isProtocolDeprecated[protocol],
            assetCategory[sellToken],
            assetCategory[buyToken]
        );
    }

    function marketTradeInfo(address protocol, address sellToken, address buyToken)
        external
        view
        returns (MarketTradeInfo memory info)
    {
        info.protocolCategory = protocolCategory[protocol];
        info.protocolDeprecated = isProtocolDeprecated[protocol];
        info.sellCategory = assetCategory[sellToken];
        info.buyCategory = assetCategory[buyToken];
        bool sellPriced = info.sellCategory & ASSET_STABLE_COIN == 0;
        bool buyPriced = info.buyCategory & ASSET_STABLE_COIN == 0;
        if (sellPriced) {
            info.sellFeed = _priceFeeds[sellToken];
            if (info.sellFeed.hasQuote) info.sellQuoteFeed = _priceFeeds[info.sellFeed.quote];
        }
        if (buyPriced) {
            info.buyFeed = _priceFeeds[buyToken];
            if (info.buyFeed.hasQuote) info.buyQuoteFeed = _priceFeeds[info.buyFeed.quote];
        }
        if ((sellPriced || buyPriced) && block.chainid != 1) info.sequencerUptimeFeed = sequencerUptimeFeed;
    }
}
