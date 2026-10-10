// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Path} from "protocol-contracts/src/libs/uniswap/v3/Uniswap.sol";
import {UniversalRoute} from "protocol-contracts/src/libs/uniswap/universal/UniversalRouter.sol";

error RouteCommandNotAllowed(uint8 command);
error RouteActionNotAllowed(uint8 action);
error RouteRecipientNotAllowed(address recipient);
error RouteHookNotAllowed(address hooks);
error RouteMalformed();

/**
 * @title RouteGuard
 * @notice Reads a market-swap route BEFORE it is handed to the adapter, and refuses one the vault
 *         cannot vouch for: every token it touches must pass the vault's own allow list, every
 *         output must land back on the adapter, and every instruction in it must be one of the few
 *         this library knows how to read.
 *
 * @dev The vault used to pass `path` through untouched. It checked the two ENDS of the trade — both
 *      registered, both allowed, both AMM-liquid — and nothing about the road between them, which
 *      the caller wrote. So an asset manager, a sub owner or a stolen owner key could sell the
 *      vault's WETH along `WETH → JUNK → USDC` through pools it was the only liquidity provider in,
 *      take the WETH out the other side as its own LP position, and leave the vault with dust. The
 *      allow list is the vault's statement of which assets it will hold; a route is a list of assets
 *      it will hold, one after another, for a few hundred microseconds each. Checking the ends of
 *      that list and not its middle was the gap.
 *
 *      Two encodings arrive here. A PACKED V3 PATH (token ‖ fee ‖ token …) goes to the pre-split
 *      adapter, and {checkV3Path} walks it. A UNIVERSAL ROUTE — Bitty's tag followed by the Universal
 *      Router's own `(commands, inputs, deadline)` — goes to the split trade adapter, and
 *      {checkUniversal} walks that: one pass over the command list, decoding each input and
 *      checking every token, currency and recipient inside it.
 *
 *      ALLOW-LIST BY CONSTRUCTION: anything this library does not recognise REVERTS. A command byte
 *      it has no case for, a v4 action it has no case for, a hooked pool, a recipient that is not the
 *      adapter, an input whose layout does not decode — all refused. That is the opposite of the
 *      usual advice about forwards compatibility, and it is deliberate: the set of instructions a
 *      router accepts is the set of ways value can leave, so a route this code cannot read is a route
 *      the vault must not sign for. The commands below are exactly the ones the quoting service
 *      builds today; the next one it learns has to be added here first.
 *
 *      What this does NOT do is bound the PRICE. A single hop through a thin pool with a minimum of
 *      one wei is still a legal route of allowed assets, so the floor the caller passes is still the
 *      only thing standing between an honest trade and a donation. That needs a reference price,
 *      which this contract has no source for today — see the open recommendation on the finding.
 */
library RouteGuard {
    using Path for bytes;

    /**
     * @dev The Universal Router's command encoding: the low six bits select the command, and 0x80
     *      marks it "may revert without failing the batch". A route is refused if that flag is set
     *      anywhere — a step that is allowed to silently not happen is a step whose output nobody
     *      checked, and every command here is one the trade depends on.
     */
    uint8 private constant FLAG_ALLOW_REVERT = 0x80;
    uint8 private constant COMMAND_TYPE_MASK = 0x3f;

    uint8 private constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint8 private constant CMD_PERMIT2_TRANSFER_FROM = 0x02;
    uint8 private constant CMD_V2_SWAP_EXACT_IN = 0x08;
    uint8 private constant CMD_WRAP_ETH = 0x0b;
    uint8 private constant CMD_UNWRAP_WETH = 0x0c;
    uint8 private constant CMD_V4_SWAP = 0x10;

    uint8 private constant ACT_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 private constant ACT_SWAP_EXACT_IN = 0x07;
    uint8 private constant ACT_SETTLE_ALL = 0x0c;
    uint8 private constant ACT_TAKE = 0x0e;
    uint8 private constant ACT_TAKE_ALL = 0x0f;

    /**
     * @dev The router's own address sentinels: 1 means "whoever called the router" — the adapter —
     *      and 2 means the router itself, which is where an intermediate leg parks its output before
     *      the next one spends it. Both are safe destinations; a literal address is only safe if it
     *      IS the adapter, because that is the balance the adapter measures the trade against.
     */
    address private constant MSG_SENDER = address(1);
    address private constant ADDRESS_THIS = address(2);

    /**
     * @dev A v4 pool, as the router's actions carry it. `hooks` must be the zero address: a hooked
     *      pool runs code of its own author's choosing on every swap, which is an arbitrary callee
     *      reached from inside the vault's transaction.
     */
    struct V4PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct V4SwapSingle {
        V4PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    struct V4PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    struct V4SwapMulti {
        address currencyIn;
        V4PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    /**
     * @notice Walk `route` and check everything in it. Reverts on the first thing it cannot vouch for.
     * @param route Either a packed v3 path or a tagged Universal route.
     * @param allowed The vault's own test for one asset — reverts if that asset may not be held.
     *        Native currency (the zero address) is exempt: it is the chain's own unit, reached only
     *        by wrapping or unwrapping the WETH the router is configured with, not a token anyone
     *        can mint.
     * @param adapter The protocol clone the output must come back to.
     */
    function check(bytes memory route, function(address) internal view allowed, address adapter) internal view {
        if (UniversalRoute.isUniversal(route)) {
            checkUniversal(route, allowed, adapter);
        } else {
            checkV3Path(route, allowed);
        }
    }

    /**
     * @notice Every token in a packed v3 path — `token ‖ fee ‖ token ‖ fee ‖ token` — must be allowed.
     * @dev A path shorter than one pool, or one whose length is not a whole number of hops, is
     *      malformed: the adapter would read a token out of whatever bytes followed.
     */
    function checkV3Path(bytes memory path, function(address) internal view allowed) internal view {
        if (path.length < 43 || (path.length - 20) % 23 != 0) revert RouteMalformed();
        bytes memory rest = path;
        while (true) {
            (address tokenA, address tokenB,) = rest.decodeFirstPool();
            allowed(tokenA);
            allowed(tokenB);
            if (!rest.hasMultiplePools()) break;
            rest = rest.skipToken();
        }
    }

    /**
     * @notice Every command in a Universal route, and every token and recipient inside each one.
     */
    function checkUniversal(bytes memory route, function(address) internal view allowed, address adapter)
        internal
        view
    {
        (bytes memory commands, bytes[] memory inputs,) = UniversalRoute.decode(route);
        if (commands.length != inputs.length) revert RouteMalformed();

        for (uint256 i; i < commands.length; ++i) {
            uint8 flagged = uint8(commands[i]);
            if (flagged & FLAG_ALLOW_REVERT != 0) revert RouteCommandNotAllowed(flagged);
            uint8 command = flagged & COMMAND_TYPE_MASK;

            if (command == CMD_V3_SWAP_EXACT_IN) {
                (address recipient,,, bytes memory path,,) =
                    abi.decode(inputs[i], (address, uint256, uint256, bytes, bool, uint256[]));
                _requireRecipient(recipient, adapter);
                checkV3Path(path, allowed);
            } else if (command == CMD_V2_SWAP_EXACT_IN) {
                (address recipient,,, address[] memory path,) =
                    abi.decode(inputs[i], (address, uint256, uint256, address[], bool));
                _requireRecipient(recipient, adapter);
                if (path.length < 2) revert RouteMalformed();
                for (uint256 j; j < path.length; ++j) {
                    allowed(path[j]);
                }
            } else if (command == CMD_V4_SWAP) {
                (bytes memory actions, bytes[] memory params) = abi.decode(inputs[i], (bytes, bytes[]));
                _checkV4(actions, params, allowed, adapter);
            } else if (command == CMD_PERMIT2_TRANSFER_FROM) {
                (address token, address recipient,) = abi.decode(inputs[i], (address, address, uint160));
                allowed(token);
                _requireRecipient(recipient, adapter);
            } else if (command == CMD_WRAP_ETH || command == CMD_UNWRAP_WETH) {
                // The token is the router's own configured WETH, not an argument; only where the
                // result lands is the caller's choice.
                (address recipient,) = abi.decode(inputs[i], (address, uint256));
                _requireRecipient(recipient, adapter);
            } else {
                revert RouteCommandNotAllowed(command);
            }
        }
    }

    /**
     * @dev The v4 half: one action list, one parameter blob per action.
     */
    function _checkV4(
        bytes memory actions,
        bytes[] memory params,
        function(address) internal view allowed,
        address adapter
    ) private view {
        if (actions.length != params.length) revert RouteMalformed();
        for (uint256 i; i < actions.length; ++i) {
            uint8 action = uint8(actions[i]);
            if (action == ACT_SWAP_EXACT_IN_SINGLE) {
                V4SwapSingle memory swap = abi.decode(params[i], (V4SwapSingle));
                _requireNoHooks(swap.poolKey.hooks);
                allowed(swap.poolKey.currency0);
                allowed(swap.poolKey.currency1);
            } else if (action == ACT_SWAP_EXACT_IN) {
                V4SwapMulti memory swap = abi.decode(params[i], (V4SwapMulti));
                allowed(swap.currencyIn);
                if (swap.path.length == 0) revert RouteMalformed();
                for (uint256 j; j < swap.path.length; ++j) {
                    _requireNoHooks(swap.path[j].hooks);
                    allowed(swap.path[j].intermediateCurrency);
                }
            } else if (action == ACT_SETTLE_ALL || action == ACT_TAKE_ALL) {
                (address currency,) = abi.decode(params[i], (address, uint256));
                allowed(currency);
            } else if (action == ACT_TAKE) {
                (address currency, address recipient,) = abi.decode(params[i], (address, address, uint256));
                allowed(currency);
                _requireRecipient(recipient, adapter);
            } else {
                revert RouteActionNotAllowed(action);
            }
        }
    }

    function _requireRecipient(address recipient, address adapter) private pure {
        if (recipient != MSG_SENDER && recipient != ADDRESS_THIS && recipient != adapter) {
            revert RouteRecipientNotAllowed(recipient);
        }
    }

    function _requireNoHooks(address hooks) private pure {
        if (hooks != address(0)) revert RouteHookNotAllowed(hooks);
    }
}
