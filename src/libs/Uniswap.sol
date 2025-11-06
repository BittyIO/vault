// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

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
