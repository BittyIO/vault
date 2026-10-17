// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    ASSET_STABLE_COIN,
    ASSET_CRYPTO,
    ASSET_AMM_LIQUID,
    PROTOCOL_LENDING,
    PROTOCOL_MARKET_TRADE
} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {GUARD_DEPLOYER} from "../helpers/GuardDeployer.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {Deprecated, NotRegistered} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    InvalidDepositableProtocol,
    MarketTradePriceTooLow,
    PriceFeedMissing
} from "../../src/interfaces/IBittyV1DeFi.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";
import {FillingMarket, MockFeed, ITrade} from "./MarketTradeGuard.t.sol";

/**
 * The market-trade checks against the real guard rather than the mock: the one {marketTradeInfo}
 * read the vault makes is answered by the code that will answer it on chain, so the two cannot drift.
 */
interface IDeposit {
    function deposit(address protocol, address asset, uint256 amount) external;
}

contract MarketTradeRealGuardTest is Test {
    BittyV1Vault vault;
    BittyV1Guard guard;
    MockERC20 usdc;
    MockERC20 weth;
    MockERC20 ldo;
    FillingMarket market;
    MockFeed wethFeed;
    address owner = makeAddr("owner");
    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.warp(1_000_000);
        BittyV1Guard impl = new BittyV1Guard();
        bytes memory init = abi.encodeCall(
            BittyV1Guard.initialize, (new address[](0), new uint8[](0), new address[](0), new uint8[](0))
        );
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        deployCodeTo("ERC1967Proxy.sol:ERC1967Proxy", abi.encode(address(impl), init), BITTY_GUARD);
        guard = BittyV1Guard(BITTY_GUARD);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ldo = new MockERC20("Lido DAO", "LDO", 18);
        market = new FillingMarket();
        guard.addAssets(_three(address(usdc), address(weth), address(ldo)), _cats());
        guard.addProtocols(_one(address(market)), _u8(PROTOCOL_MARKET_TRADE));

        wethFeed = new MockFeed();
        wethFeed.set(2_000e8, block.timestamp, block.timestamp);
        MockFeed ldoFeed = new MockFeed();
        ldoFeed.setDecimals(18);
        ldoFeed.set(0.0005e18, block.timestamp, block.timestamp); // LDO / ETH: $1
        uint32[] memory ages = new uint32[](2);
        (ages[0], ages[1]) = (1 hours, 1 hours);
        address[] memory quotes = new address[](2);
        quotes[1] = address(weth);
        guard.setPriceFeeds(_two(address(weth), address(ldo)), _two(address(wethFeed), address(ldoFeed)), ages, quotes);
        vm.stopPrank();

        BittyV1Vault vimpl = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(vimpl),
                    abi.encodeCall(
                        BittyV1Vault.initialize, (owner, makeAddr("gasWrapped"), false, address(0), 0, new bytes[](0))
                    )
                ))
        );
        weth.mint(address(vault), 10e18);
        ldo.mint(address(vault), 1_000e18);

        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(UNCHANGED, UNCHANGED, 1_000_000));
    }

    function _sell(address sellToken, uint256 amount, address buyToken, uint256 fill) internal {
        vm.prank(owner);
        ITrade(address(vault)).marketSell(address(market), sellToken, amount, buyToken, 0, abi.encode(fill));
    }

    function test_aFairTradeGoesThroughTheRealGuard() public {
        _sell(address(weth), 1e18, address(usdc), 1_990e6);
        assertEq(usdc.balanceOf(address(vault)), 1_990e6);
    }

    function test_theRealGuardsFeedStopsARiggedPool() public {
        vm.expectRevert(MarketTradePriceTooLow.selector);
        _sell(address(weth), 10e18, address(usdc), 1);
    }

    function test_aQuotedFeedChainsThroughTheRealGuard() public {
        _sell(address(ldo), 500e18, address(usdc), 475e6); // LDO / ETH × ETH / USD = $1, 5% under
        vm.expectRevert(MarketTradePriceTooLow.selector);
        _sell(address(ldo), 500e18, address(usdc), 475e6 - 1);
    }

    function test_anAssetWithNoFeedOnTheRealGuardCannotBeSold() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.prank(GUARD_DEPLOYER);
        guard.addAssets(_one(address(other)), _u8(ASSET_CRYPTO | ASSET_AMM_LIQUID));
        other.mint(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(PriceFeedMissing.selector, address(other)));
        _sell(address(other), 1e18, address(usdc), 1_000e6);
    }

    function test_aDeprecatedProtocolOnTheRealGuardIsRefused() public {
        vm.prank(GUARD_DEPLOYER);
        guard.deprecateProtocols(_one(address(market)));
        vm.expectRevert(Deprecated.selector);
        _sell(address(weth), 1e18, address(usdc), 2_000e6);
    }

    /**
     * The deposit asks the guard only whether a protocol is registered, relying on the real guard
     * taking a deprecated protocol out of its registered set.
     */
    function test_aProtocolDeprecatedOnTheRealGuardTakesNoDeposit() public {
        MockLendingProtocol lending = new MockLendingProtocol();
        vm.startPrank(GUARD_DEPLOYER);
        guard.addProtocols(_one(address(lending)), _u8(PROTOCOL_LENDING));
        guard.deprecateProtocols(_one(address(lending)));
        vm.stopPrank();
        usdc.mint(address(vault), 1e6);
        vm.prank(owner);
        vm.expectRevert(InvalidDepositableProtocol.selector);
        IDeposit(address(vault)).deposit(address(lending), address(usdc), 1e6);
    }

    function test_anAssetTheRealGuardRemovedIsRefused() public {
        vm.prank(GUARD_DEPLOYER);
        guard.removeAssets(_one(address(weth)));
        vm.expectRevert(NotRegistered.selector);
        _sell(address(weth), 1e18, address(usdc), 2_000e6);
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (a, b);
    }

    function _three(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _u8(uint8 v) internal pure returns (uint8[] memory r) {
        r = new uint8[](1);
        r[0] = v;
    }

    function _cats() internal pure returns (uint8[] memory r) {
        r = new uint8[](3);
        (r[0], r[1], r[2]) =
        (ASSET_STABLE_COIN | ASSET_AMM_LIQUID, ASSET_CRYPTO | ASSET_AMM_LIQUID, ASSET_CRYPTO | ASSET_AMM_LIQUID);
    }
}
