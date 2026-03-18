// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IProvider} from "./IProvider.sol";

/**
 * @title IAMMProvider
 * @notice Interface for AMM (swap and liquidity) providers.
 */
interface IAMMProvider is IProvider {
    /**
     * @notice Swap tokens on the AMM provider.
     * @dev Swap tokens on the AMM provider.
     * @param data The data for the swap.
     * @dev Only the asset manager can execute it.
     */
    function swap(bytes memory data) external payable;

    /**
     * @notice Add liquidity to the AMM provider.
     * @dev Add liquidity to the AMM provider.
     * @param data The data for the add liquidity.
     * @dev Only the asset manager can execute it.
     */
    function addLiquidity(bytes memory data) external payable;

    /**
     * @notice Remove liquidity from the AMM provider.
     * @dev Remove liquidity from the AMM provider.
     * @param data The data for the remove liquidity.
     * @dev Only the asset manager can execute it.
     */
    function removeLiquidity(bytes memory data) external payable;

    /**
     * @notice Claim fees from the AMM provider.
     * @dev Claim fees from the AMM provider.
     * @param data The data for the claim fees.
     * @dev Only the asset manager can execute it.
     */
    function claimFees(bytes memory data) external payable;

    /**
     * @notice Get the liquidity of the AMM provider.
     * @dev Get the liquidity of the AMM provider.
     * @param data The data for the get liquidity.
     * @dev Only the asset manager can execute it.
     */
    function getLiquidity(bytes memory data) external view returns (uint256);
}
