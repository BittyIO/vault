// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN, ASSET_CRYPTO, ASSET_AMM_LIQUID} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockMarketProtocol} from "../helpers/MockMarketProtocol.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {MockIntentProtocol} from "../helpers/MockIntentProtocol.sol";
import {MockStakingProtocol} from "../helpers/MockStakingProtocol.sol";
import {MARKET_TRADE_ID, LENDING_ID, STAKING_ID, INTENT_ID} from "../helpers/CategoryIds.sol";
import {MockFeed} from "./MarketTradeGuard.t.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {ReentrantCall} from "../../src/interfaces/IBittyV1Vault.sol";
import {MarketTradePriceTooLow} from "../../src/interfaces/IBittyV1DeFi.sol";
import {
    BITTY_GUARD,
    MIN_RISK_TIMELOCK,
    PERM_YIELD,
    PERM_SUPPLY,
    PERM_MARKET_TRADE,
    PERM_INTENT
} from "../../src/logic/Constants.sol";

/**
 * @dev The account behind the trade — a smart-account owner or manager. Armed with one call, it makes
 *      it when the route calls back, and keeps what came back.
 */
contract Reenterer {
    address public target;
    bytes public data;
    bytes public returned;
    bool public swallow; // carry on when the armed call fails, as a hook that must not break its route would

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function setSwallow(bool swallow_) external {
        swallow = swallow_;
    }

    function call(address to, bytes calldata data_) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data_);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    function onRoute() external {
        if (target == address(0)) return;
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok && !swallow) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        returned = ret;
    }
}

/**
 * @dev A route through the caller's own pool: the whole sale goes to `pool`, the caller's code runs
 *      (a transfer hook, a pool hook, ETH sent to a contract — here, `Reenterer.onRoute`), and then
 *      `fill` of the bought token is paid. `path` is `abi.encode(pool, reenterer, fill)`.
 */
contract HookedMarket is MockMarketProtocol {
    function swap(bytes memory data, address recipient) external payable override {
        (address sellToken, uint256 sellAmount, address buyToken,, bytes memory path) =
            abi.decode(data, (address, uint256, address, uint256, bytes));
        (address pool, address reenterer, uint256 fill) = abi.decode(path, (address, address, uint256));
        IERC20(sellToken).transferFrom(msg.sender, pool, sellAmount);
        Reenterer(reenterer).onRoute();
        if (fill > 0) MockERC20(buyToken).mint(recipient, fill);
    }
}

/**
 * The fix-review finding: a market trade is judged by the vault's balances before and after the swap,
 * so anything the caller's route did to those balances mid-swap — unwinding a position into the vault,
 * a second trade, wrapping idle ETH, an intent order filling — was counted as the trade's own. While a
 * trade runs every balance-moving entry point refuses, and the signature check fails, so the balances
 * the trade is judged by move only by the swap.
 *
 * And the role half of it: a grant to trade at market alone no longer reaches the unwind functions.
 */
contract MarketTradeReentrancyTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 weth;
    WETH gasWeth;
    HookedMarket market;
    MockLendingProtocol lending;
    MockIntentProtocol intent;
    Reenterer account;
    address pool = makeAddr("pool");
    address manager = makeAddr("manager");

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        account = new Reenterer();
        gasWeth = new WETH();
        BittyV1Vault impl = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        BittyV1Vault.initialize,
                        (address(account), address(gasWeth), false, address(0), 0, new bytes[](0))
                    )
                ))
        );

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        market = new HookedMarket();
        lending = new MockLendingProtocol();
        intent = new MockIntentProtocol(makeAddr("settlement"));

        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        guard.setAsset(address(weth), ASSET_CRYPTO | ASSET_AMM_LIQUID);
        guard.setAsset(address(gasWeth), ASSET_CRYPTO | ASSET_AMM_LIQUID);
        guard.setProtocol(address(market), MARKET_TRADE_ID);
        guard.setProtocol(address(lending), LENDING_ID);
        guard.setProtocol(address(intent), INTENT_ID);

        MockFeed feed = new MockFeed();
        feed.set(2_000e8, block.timestamp, block.timestamp);
        guard.setPriceFeed(address(weth), address(feed), 1 hours, address(0));
        guard.setPriceFeed(address(gasWeth), address(feed), 1 hours, address(0));

        // 100 idle WETH to sell, and 200,000 USDC and 100 WETH lent out to unwind.
        weth.mint(address(vault), 200e18);
        usdc.mint(address(vault), 200_000e6);
        _asOwner(abi.encodeCall(BittyV1VaultDeFiFacet.deposit, (address(lending), address(usdc), 200_000e6)));
        _asOwner(abi.encodeCall(BittyV1VaultDeFiFacet.deposit, (address(lending), address(weth), 100e18)));
    }

    function _asOwner(bytes memory data) internal returns (bytes memory) {
        return account.call(address(vault), data);
    }

    function _f() internal view returns (BittyV1VaultDeFiFacet) {
        return BittyV1VaultDeFiFacet(payable(address(vault)));
    }

    function _sellCall(address sellToken, uint256 amount, address buyToken, uint256 fill)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            BittyV1VaultDeFiFacet.marketSell,
            (address(market), sellToken, amount, buyToken, 0, abi.encode(pool, address(account), fill))
        );
    }

    /**
     * Sell 100 WETH (200,000 USD) for one unit of USDC, the route calling `reentry` on the way, and
     * expect it refused with `expected`.
     */
    function _sellForNothing(bytes memory reentry, bytes4 expected) internal {
        account.arm(address(vault), reentry);
        vm.expectRevert(expected);
        _asOwner(_sellCall(address(weth), 100e18, address(usdc), 1));
    }

    // ── the sale the guard exists for ────────────────────────────────────────

    function test_control_withoutReentryTheSaleIsRefused() public {
        _sellForNothing("", MarketTradePriceTooLow.selector);
    }

    function test_unwindingTheBoughtTokenMidSaleIsRefused() public {
        _sellForNothing(
            abi.encodeCall(BittyV1VaultDeFiFacet.withdraw, (address(lending), address(usdc), 200_000e6)),
            ReentrantCall.selector
        );
        assertEq(weth.balanceOf(pool), 0, "nothing reached the pool");
    }

    function test_unwindingTheSoldTokenMidSaleIsRefused() public {
        _sellForNothing(
            abi.encodeCall(BittyV1VaultDeFiFacet.withdraw, (address(lending), address(weth), 100e18)),
            ReentrantCall.selector
        );
    }

    function test_withdrawsMidSaleIsRefused() public {
        address[] memory protocols = new address[](1);
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (protocols[0], assets[0], amounts[0]) = (address(lending), address(usdc), 200_000e6);
        _sellForNothing(
            abi.encodeCall(BittyV1VaultDeFiFacet.withdraws, (protocols, assets, amounts)), ReentrantCall.selector
        );
    }

    function test_aSendThatPullsFromAPositionMidSaleIsRefused() public {
        address[] memory protocols = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (protocols[0], amounts[0]) = (address(lending), 200_000e6);
        _sellForNothing(
            abi.encodeCall(BittyV1Vault.send, (makeAddr("anyone"), address(usdc), 1, protocols, amounts)),
            ReentrantCall.selector
        );
    }

    function test_aSecondTradeMidSaleIsRefused() public {
        _sellForNothing(_sellCall(address(weth), 1e18, address(usdc), 2_000e6), ReentrantCall.selector);
    }

    function test_aDepositMidSaleIsRefused() public {
        _sellForNothing(
            abi.encodeCall(BittyV1VaultDeFiFacet.deposit, (address(lending), address(weth), 1e18)),
            ReentrantCall.selector
        );
    }

    /**
     * Anyone may wrap the vault's ETH; mid-sale it would count as WETH bought.
     */
    function test_wrappingIdleEthMidSaleIsRefused() public {
        vm.deal(address(vault), 100 ether);
        usdc.mint(address(vault), 200_000e6);
        account.arm(address(vault), abi.encodeCall(BittyV1Vault.wrapNative, ()));
        vm.expectRevert(ReentrantCall.selector);
        _asOwner(_sellCall(address(usdc), 200_000e6, address(gasWeth), 0));
    }

    /**
     * No signed intent order may fill mid-sale: the vault's signature check fails while it runs.
     */
    function test_noIntentOrderValidatesMidTrade() public {
        _asOwner(abi.encodeCall(BittyV1VaultDeFiFacet.approveIntentSpender, (address(intent), address(usdc))));
        assertEq(_f().isValidSignature(bytes32(0), ""), bytes4(0x1626ba7e), "outside a trade it validates");

        account.arm(address(vault), abi.encodeCall(BittyV1VaultDeFiFacet.isValidSignature, (bytes32(0), "")));
        _asOwner(_sellCall(address(weth), 1e18, address(usdc), 2_000e6));
        assertEq(abi.decode(account.returned(), (bytes4)), bytes4(0xffffffff), "mid-trade it does not");

        account.arm(
            address(vault),
            abi.encodeCall(
                BittyV1VaultDeFiFacet.isOffchainOrderAuthorized, (address(account), address(weth), address(usdc), 1)
            )
        );
        _asOwner(_sellCall(address(weth), 1e18, address(usdc), 2_000e6));
        assertFalse(abi.decode(account.returned(), (bool)), "nor is an off-chain order authorised");
    }

    /**
     * The lock lasts the trade, not the transaction: a fair trade, then an unwind, in one go.
     */
    function test_theLockIsReleasedWhenTheTradeEnds() public {
        _asOwner(_sellCall(address(weth), 1e18, address(usdc), 2_000e6));
        _asOwner(abi.encodeCall(BittyV1VaultDeFiFacet.withdraw, (address(lending), address(usdc), 1e6)));
        _asOwner(abi.encodeCall(BittyV1Vault.wrapNative, ()));
        assertEq(_f().isValidSignature(bytes32(0), ""), bytes4(0xffffffff), "no intent clone yet");
    }

    // ── who may unwind ───────────────────────────────────────────────────────

    function _appoint(uint32 permissions) internal {
        _asOwner(
            abi.encodeCall(
                BittyV1VaultDeFiFacet.setAssetManager, (manager, uint64(block.timestamp + 365 days), permissions)
            )
        );
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
    }

    function test_aTradingOnlyManagerCannotUnwind() public {
        _appoint(PERM_MARKET_TRADE | PERM_INTENT);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, manager));
        _f().withdraw(address(lending), address(usdc), 1e6);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, manager));
        _f().claimWithdrawal(address(lending), 0);
    }

    /**
     * Out takes the grant that in did: lending needs supply, staking needs yield.
     */
    function test_unwindingTakesThePermissionThePositionWasOpenedWith() public {
        MockStakingProtocol staking = new MockStakingProtocol();
        guard.setProtocol(address(staking), STAKING_ID);
        _asOwner(abi.encodeCall(BittyV1VaultDeFiFacet.deposit, (address(staking), address(weth), 10e18)));
        bytes memory unauthorized =
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, manager);

        _appoint(PERM_SUPPLY);
        vm.prank(manager);
        _f().withdraw(address(lending), address(usdc), 1e6);
        vm.prank(manager);
        vm.expectRevert(unauthorized);
        _f().withdraw(address(staking), address(weth), 1e18);

        _appoint(PERM_YIELD);
        vm.prank(manager);
        _f().withdraw(address(staking), address(weth), 1e18);
        vm.prank(manager);
        vm.expectRevert(unauthorized);
        _f().withdraw(address(lending), address(usdc), 1e6);

        // A batch is held to each protocol it names.
        address[] memory protocols = new address[](2);
        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (protocols[0], assets[0], amounts[0]) = (address(staking), address(weth), 1e18);
        (protocols[1], assets[1], amounts[1]) = (address(lending), address(usdc), 1e6);
        vm.prank(manager);
        vm.expectRevert(unauthorized);
        _f().withdraws(protocols, assets, amounts);

        assertEq(usdc.balanceOf(address(vault)), 1e6);
        assertEq(weth.balanceOf(address(vault)), 91e18);
    }

    function test_onlyAnIntentManagerMayCancelOrders() public {
        _asOwner(abi.encodeCall(BittyV1VaultDeFiFacet.approveIntentSpender, (address(intent), address(usdc))));
        _appoint(PERM_SUPPLY | PERM_YIELD | PERM_MARKET_TRADE);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, manager));
        _f().cancelIntentOrder(address(intent), hex"01");
        assertFalse(_f().isOffchainCancellationAuthorized(manager));

        _appoint(PERM_INTENT);
        vm.prank(manager);
        _f().cancelIntentOrder(address(intent), hex"01");
        assertTrue(_f().isOffchainCancellationAuthorized(manager));
    }
}
