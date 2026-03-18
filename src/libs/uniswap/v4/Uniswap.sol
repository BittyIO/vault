// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

struct PoolKey {
    /// @notice The lower currency of the pool, sorted numerically
    address currency0;
    /// @notice The higher currency of the pool, sorted numerically
    address currency1;
    /// @notice The pool LP fee, capped at 1_000_000. If the highest bit is 1, the pool has a dynamic fee and must be exactly equal to 0x800000
    uint24 fee;
    /// @notice Ticks that involve positions must be a multiple of tick spacing
    int24 tickSpacing;
    /// @notice The hooks of the pool
    address hooks;
}

struct PathKey {
    address intermediateCurrency;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
    bytes hookData;
}

using PathKeyLibrary for PathKey global;

/// @title PathKey Library
/// @notice Memory-oriented version of v4-periphery/src/libraries/PathKeyLibrary.sol
/// @dev Handles PathKey operations in memory rather than calldata for router operations
library PathKeyLibrary {
    /// @notice Get the pool and swap direction for a given PathKey
    /// @param params the given PathKey
    /// @param currencyIn the input currency
    /// @return poolKey the pool key of the swap
    /// @return zeroForOne the direction of the swap, true if currency0 is being swapped for currency1
    function getPoolAndSwapDirection(PathKey memory params, address currencyIn)
        internal
        pure
        returns (PoolKey memory poolKey, bool zeroForOne)
    {
        address currencyOut = params.intermediateCurrency;
        (address currency0, address currency1) =
            currencyIn < currencyOut ? (currencyIn, currencyOut) : (currencyOut, currencyIn);

        zeroForOne = currencyIn == currency0;
        poolKey = PoolKey(currency0, currency1, params.fee, params.tickSpacing, params.hooks);
    }
}

struct BaseData {
    uint256 amount;
    uint256 amountLimit;
    address payer;
    address receiver;
    uint8 flags;
}

/// @title SwapFlags Library
/// @notice Library for managing swap configuration flags using bitwise operations
/// @dev Provides constants and utilities for working with swap flags encoded as uint8
library SwapFlags {
    /// @notice Flag indicating a single pool swap vs multi-hop swap
    /// @dev Bit position 0 (0b00001)
    uint8 constant SINGLE_SWAP = 1 << 0;

    /// @notice Flag indicating exact output swap vs exact input swap
    /// @dev Bit position 1 (0b00010)
    uint8 constant EXACT_OUTPUT = 1 << 1;

    /// @notice Flag indicating input token is ERC6909
    /// @dev Bit position 2 (0b00100)
    uint8 constant INPUT_6909 = 1 << 2;

    /// @notice Flag indicating output token is ERC6909
    /// @dev Bit position 3 (0b01000)
    uint8 constant OUTPUT_6909 = 1 << 3;

    /// @notice Flag indicating swap uses Permit2 for token approvals
    /// @dev Bit position 4 (0b10000)
    uint8 constant PERMIT2 = 1 << 4;

    /// @notice Unpacks individual boolean flags from packed uint8
    /// @param flags The packed uint8 containing all flag bits
    /// @return singleSwap True if single pool swap
    /// @return exactOutput True if exact output swap
    /// @return input6909 True if input token is ERC6909
    /// @return output6909 True if output token is ERC6909
    /// @return permit2 True if using Permit2
    function unpackFlags(uint8 flags)
        internal
        pure
        returns (bool singleSwap, bool exactOutput, bool input6909, bool output6909, bool permit2)
    {
        singleSwap = flags & SINGLE_SWAP != 0;
        exactOutput = flags & EXACT_OUTPUT != 0;
        input6909 = flags & INPUT_6909 != 0;
        output6909 = flags & OUTPUT_6909 != 0;
        permit2 = flags & PERMIT2 != 0;
    }
}

type PoolId is bytes32;

library PoolIdLibrary {
    /// @notice Returns value equal to keccak256(abi.encode(poolKey))
    function toId(PoolKey memory poolKey) internal pure returns (PoolId poolId) {
        assembly ("memory-safe") {
            // 0xa0 represents the total size of the poolKey struct (5 slots of 32 bytes)
            poolId := keccak256(poolKey, 0xa0)
        }
    }
}

library PoolStateLibrary {
    bytes32 public constant POOLS_SLOT = bytes32(uint256(6));

    /**
     * @notice Get Slot0 of the pool: sqrtPriceX96, tick, protocolFee, lpFee
     * @dev Corresponds to pools[poolId].slot0
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @return sqrtPriceX96 The square root of the price of the pool, in Q96 precision.
     * @return tick The current tick of the pool.
     * @return protocolFee The protocol fee of the pool.
     * @return lpFee The swap fee of the pool.
     */
    function getSlot0(IPoolManager manager, PoolId poolId)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        bytes32 data = manager.extsload(stateSlot);

        //   24 bits  |24bits|24bits      |24 bits|160 bits
        // 0x000000   |000bb8|000000      |ffff75 |0000000000000000fe3aa841ba359daa0ea9eff7
        // ---------- | fee  |protocolfee | tick  | sqrtPriceX96
        assembly ("memory-safe") {
            // bottom 160 bits of data
            sqrtPriceX96 := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            // next 24 bits of data
            tick := signextend(2, shr(160, data))
            // next 24 bits of data
            protocolFee := and(shr(184, data), 0xFFFFFF)
            // last 24 bits of data
            lpFee := and(shr(208, data), 0xFFFFFF)
        }
    }

    function _getPoolStateSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
    }
}

interface IPoolManager {
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IUniswapV4Router04 {
    /// @notice Generic multi-pool swap function that accepts pre-encoded calldata
    /// @dev Minor optimization to reduce the number of onchain abi.encode calls
    /// @param data Pre-encoded swap data in one of the following formats:
    ///     1. For single-pool swaps: abi.encode(
    ///         BaseData baseData,             // struct containing swap parameters
    ///         bool zeroForOne,               // direction of swap
    ///         PoolKey poolKey,               // key of the pool to swap through
    ///         bytes hookData                 // data to pass to hooks
    ///     )
    ///     2. For multi-pool swaps: abi.encode(
    ///         BaseData baseData,             // struct containing swap parameters
    ///         Currency startCurrency,        // initial currency in the swap
    ///         PathKey[] path                 // array of path keys defining the route
    ///     )
    ///
    ///     PERMIT2 EXTENSION:
    ///     1. For single pool swaps: abi.encode(
    ///         BaseData baseData,             // struct containing swap parameters
    ///         bool zeroForOne,               // direction of swap
    ///         PoolKey poolKey,               // key of the pool to swap through
    ///         bytes hookData,                // data to pass to hooks
    ///         PermitPayload permitPayload    // permit2 signature payload
    ///     )
    ///     2. For multi-pool swaps: abi.encode(
    ///         BaseData baseData,             // struct containing swap parameters
    ///         Currency startCurrency,        // initial currency in the swap
    ///         PathKey[] path,                // array of path keys defining the route
    ///         PermitPayload permitPayload    // permit2 signature payload
    ///     )
    ///     Where BaseData.flags contains permit2 flag, and PermitPayload contains:
    ///         - permit: ISignatureTransfer.PermitTransferFrom
    ///         - signature: bytes
    ///
    /// @param deadline block.timestamp must be before this value, otherwise the transaction will revert
    /// @return Delta the balance changes from the swap
    function swap(bytes calldata data, uint256 deadline) external payable returns (int256);
}
