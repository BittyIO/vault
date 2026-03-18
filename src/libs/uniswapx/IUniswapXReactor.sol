// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/// @title UniswapX Reactor Interface
/// @notice Minimal interface for UniswapX order execution (V2 Dutch, Limit, etc.)
interface IUniswapXReactor {
    struct SignedOrder {
        bytes order;
        bytes sig;
    }

    /// @notice Execute a single order
    function execute(SignedOrder calldata order) external payable;
}
