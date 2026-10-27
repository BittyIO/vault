// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {ASSET_STABLE_COIN, ASSET_CRYPTO, ASSET_AMM_LIQUID} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {MARKET_TRADE_ID, LENDING_ID} from "../helpers/CategoryIds.sol";
import {MockFeed} from "../local/MarketTradeGuard.t.sol";
import {Reenterer} from "../local/MarketTradeReentrancy.t.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {ReentrantCall} from "../../src/interfaces/IBittyV1Vault.sol";
import {MarketTradePriceTooLow} from "../../src/interfaces/IBittyV1DeFi.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

import {UniswapUniversalTradeProtocol} from "protocol-contracts/src/protocols/UniswapUniversalTradeProtocol.sol";
import {UniversalRoute} from "protocol-contracts/src/libs/uniswap/universal/UniversalRouter.sol";
import {Path} from "protocol-contracts/src/libs/uniswap/v3/Uniswap.sol";
import {mainnet} from "protocol-contracts/script/addresses.sol";

interface IV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @dev Any token anyone can deploy, routed through as an intermediate hop — the vault never sees it,
 *      since only the two legs it trades are checked. Each transfer runs its creator's code: the hook
 *      the finding says a route can carry.
 */
contract HookToken is MockERC20 {
    Reenterer public hook;

    constructor() MockERC20("Hook", "HOOK", 18) {}

    function setHook(Reenterer hook_) external {
        hook = hook_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _callHook();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _callHook();
        return super.transferFrom(from, to, amount);
    }

    function _callHook() private {
        if (address(hook) != address(0)) hook.onRoute();
    }
}

/**
 * The fix-review finding, against the PRODUCTION route: the real Universal Router 2.1.2 and Permit2 on a
 * mainnet fork, through the pinned UniswapUniversalTradeProtocol. The local PoC stood in a mock market
 * for the router; this shows a live route does run the caller's code mid-swap.
 *
 * The caller builds the route out of two Uniswap V3 pools it created itself — WETH/HOOK and HOOK/USDC,
 * each holding dust — so the vault's WETH goes for a fraction of a cent. Between the hops the router
 * moves HOOK, and HOOK's transfer calls back into the vault. Before the fix, that callback withdrew the
 * vault's own lent USDC into the vault and the sale passed the oracle check as if paid in full. Now any
 * balance-moving call refuses while the trade runs.
 *
 *   Run with:  FOUNDRY_PROFILE=fork ALCHEMY_KEY=<key> forge test --match-path test/fork/MarketTradeReentrancy.fork.t.sol
 */
contract MarketTradeReentrancyForkTest is Test {
    address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    uint24 constant FEE = 10_000; // tick spacing 200
    int24 constant FULL_RANGE = 887_200; // the widest ticks on that spacing
    uint160 constant ONE_TO_ONE = uint160(1 << 96); // sqrtPriceX96 at a 1:1 raw price
    uint8 constant CMD_V3_SWAP_EXACT_IN = 0x00;
    address constant MSG_SENDER = address(1); // the router's "whoever called me": output lands on the adapter
    uint24 constant REAL_POOL_FEE = 500; // the WETH/USDC 0.05% pool

    BittyV1Vault vault;
    UniswapUniversalTradeProtocol trade;
    MockLendingProtocol lending;
    HookToken hook;
    Reenterer account;

    IERC20 weth = IERC20(mainnet.WETH);
    IERC20 usdc = IERC20(mainnet.USDC);

    function setUp() public {
        vm.createSelectFork("mainnet");

        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        MockGuard guard = MockGuard(BITTY_GUARD);

        account = new Reenterer();
        BittyV1Vault impl = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        BittyV1Vault.initialize, (address(account), mainnet.WETH, false, address(0), 0, new bytes[](0))
                    )
                ))
        );

        trade = new UniswapUniversalTradeProtocol(mainnet.UNISWAP_UNIVERSAL_ROUTER, mainnet.PERMIT2, BITTY_GUARD);
        lending = new MockLendingProtocol();
        guard.setProtocol(address(trade), MARKET_TRADE_ID);
        guard.setProtocol(address(lending), LENDING_ID);
        guard.setAsset(mainnet.WETH, ASSET_CRYPTO | ASSET_AMM_LIQUID);
        guard.setAsset(mainnet.USDC, ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        // The oracle, pinned so the numbers below are the fork block's no matter which block it is.
        MockFeed feed = new MockFeed();
        feed.set(2_000e8, block.timestamp, block.timestamp);
        guard.setPriceFeed(mainnet.WETH, address(feed), 1 hours, address(0));

        // 1 idle WETH to sell, and 2,000 USDC lent out — the position the callback would unwind.
        deal(mainnet.WETH, address(vault), 1e18);
        deal(mainnet.USDC, address(vault), 2_000e6);
        account.call(
            address(vault), abi.encodeCall(BittyV1VaultDeFiFacet.deposit, (address(lending), mainnet.USDC, 2_000e6))
        );

        // The caller's own route: WETH -> HOOK -> USDC, through two pools of dust it created.
        hook = new HookToken();
        _dustPool(mainnet.WETH, address(hook), 1e6);
        _dustPool(address(hook), mainnet.USDC, 1e3);
    }

    function _dustPool(address a, address b, uint128 liquidity) internal {
        IV3Pool pool = IV3Pool(IV3Factory(V3_FACTORY).createPool(a, b, FEE));
        pool.initialize(ONE_TO_ONE);
        pool.mint(address(this), -FULL_RANGE, FULL_RANGE, liquidity, "");
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        _payPool(IV3Pool(msg.sender).token0(), amount0);
        _payPool(IV3Pool(msg.sender).token1(), amount1);
    }

    function _payPool(address token, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(hook)) hook.mint(msg.sender, amount);
        else deal(token, msg.sender, IERC20(token).balanceOf(msg.sender) + amount);
    }

    function _route(address[] memory tokens, uint24[] memory fees, uint256 amountIn)
        internal
        view
        returns (bytes memory)
    {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(MSG_SENDER, amountIn, 0, Path.encodePath(tokens, fees), true, new uint256[](0));
        return UniversalRoute.encode(abi.encodePacked(CMD_V3_SWAP_EXACT_IN), inputs, block.timestamp + 60);
    }

    /**
     * Sell the vault's 1 WETH for USDC through the caller's two dust pools.
     */
    function _sellThroughTheCallersPools() internal {
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (mainnet.WETH, address(hook), mainnet.USDC);
        uint24[] memory fees = new uint24[](2);
        (fees[0], fees[1]) = (FEE, FEE);
        account.call(
            address(vault),
            abi.encodeCall(
                BittyV1VaultDeFiFacet.marketSell,
                (address(trade), mainnet.WETH, 1e18, mainnet.USDC, 0, _route(tokens, fees, 1e18))
            )
        );
    }

    /**
     * The route alone: the dust pools pay next to nothing, and the oracle check refuses the sale.
     */
    function test_control_theCallersRouteIsRefusedOnPrice() public {
        vm.expectRevert(MarketTradePriceTooLow.selector);
        _sellThroughTheCallersPools();
    }

    /**
     * The same route with the hook armed to unwind the lent USDC mid-swap. The vault is reached — the
     * real router runs the caller's code mid-trade — but the unwind is refused, so the sale is judged
     * on what the dust pools paid and fails on price. Before the fix the unwind landed, the vault
     * looked paid in full, and the sale went through.
     *
     * The hook carries on past its own failure: the router wraps any revert in a token transfer as its
     * own "TF", so a refusal that broke the route would not say what was refused.
     */
    function test_unwindingMidRouteThroughTheRealRouterIsRefused() public {
        bytes memory unwind = abi.encodeCall(BittyV1VaultDeFiFacet.withdraw, (address(lending), mainnet.USDC, 2_000e6));
        hook.setHook(account);
        account.arm(address(vault), unwind);
        account.setSwallow(true);

        vm.expectCall(address(vault), unwind);
        vm.expectRevert(MarketTradePriceTooLow.selector);
        _sellThroughTheCallersPools();
    }

    /**
     * And when the hook does not carry on, the refusal breaks the route outright.
     */
    function test_aHookThatInsistsBreaksTheRoute() public {
        hook.setHook(account);
        account.arm(
            address(vault), abi.encodeCall(BittyV1VaultDeFiFacet.withdraw, (address(lending), mainnet.USDC, 2_000e6))
        );
        vm.expectRevert(bytes("TF"));
        _sellThroughTheCallersPools();
    }

    /**
     * The lock costs a fair trade nothing: WETH for USDC on the real WETH/USDC pool, then an unwind.
     */
    function test_aFairTradeStillGoesThroughAndReleasesTheLock() public {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (mainnet.WETH, mainnet.USDC);
        uint24[] memory fees = new uint24[](1);
        fees[0] = REAL_POOL_FEE;
        // A fork block's real price may sit off the pinned oracle; follow it so only the lock is tested.
        uint256 usdcBefore = usdc.balanceOf(address(vault));
        account.call(
            address(vault),
            abi.encodeCall(
                BittyV1VaultDeFiFacet.marketSell,
                (address(trade), mainnet.WETH, 0.01e18, mainnet.USDC, 0, _route(tokens, fees, 0.01e18))
            )
        );
        assertGt(usdc.balanceOf(address(vault)), usdcBefore, "USDC came back from the real pool");

        account.call(
            address(vault), abi.encodeCall(BittyV1VaultDeFiFacet.withdraw, (address(lending), mainnet.USDC, 1e6))
        );
    }
}
