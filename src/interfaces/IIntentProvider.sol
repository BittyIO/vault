// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProvider} from "./IProvider.sol";

/**
 * @title IIntentProvider
 * @notice Interface for intent providers.
 * @dev This interface is used to trade the asset.
 */
interface IIntentProvider is IProvider {
    /**
     * @notice Emitted when a trade is executed.
     * @param data The data of the trade.
     * @param sender The sender of the trade.
     * @param provider The provider of the trade.
     */
    event Trade(bytes data, address indexed sender, address indexed provider);

    /**
     * @notice Emitted when a trade is canceled.
     * @param data The data of the trade.
     * @param sender The sender of the trade.
     * @param provider The provider of the trade.
     */
    event CancelTrade(bytes data, address indexed sender, address indexed provider);

    /**
     * @notice Trade the asset.
     * @dev Trade the asset.
     * @param data The data of the trade.
     */
    function trade(bytes memory data) external payable;

    /**
     * @notice Check if the signature is valid.
     * @dev Check if the signature is valid.
     * @param hash The hash of the trade.
     * @param signature The signature of the trade.
     * @return The magic value of the signature check.
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);

    /**
     * @notice Cancel a trade/order.
     * @dev Provider-specific encoding. UniswapX: abi.encode(bytes32 hash).
     *      CoW: abi.encode(bytes32 orderDigest, uint32 validTo).
     * @param data Encoded cancellation data (hash or orderDigest+validTo).
     */
    function cancelTrade(bytes memory data) external;
}
