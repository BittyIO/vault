// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IProvider} from "./IProvider.sol";

error ApprovalNotFound();
error OrderNotExpired();

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
    function trade(bytes memory data) external;

    /**
     * @notice Check if the signature is valid.
     * @dev Check if the signature is valid.
     * @param hash The hash of the trade.
     * @param signature The signature of the trade.
     * @return The magic value of the signature check.
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);

    /**
     * @notice Cancel a trade/order and revoke outstanding token approvals on the provider clone when applicable.
     * @dev CoW: abi.encode(bytes32 orderDigest, uint32 validTo). Revokes vault relayer allowance for the sell token.
     *      UniswapX: abi.encode(bytes32 hash) when hash was set in trade with hashToApprove; revokes Permit2 allowance.
     *      UniswapX (trade without hashToApprove but ERC20 sell): abi.encode(bytes32(0), address sellToken).
     */
    function cancelTrade(bytes memory data) external;

    /**
     * @notice Revoke token approvals to the settlement/relayer contract for multiple tokens.
     * @dev Silently skips tokens whose current allowance is already zero.
     * @param tokens The sell tokens whose approvals should be revoked.
     */
    function revokeApprovals(address[] calldata tokens) external;

    /**
     * @notice Permissionlessly clean up multiple expired orders: revokes approvals, transfers
     *         any remaining sell token balances back to the owner.
     * @dev Reverts with OrderNotExpired if validTo has not passed yet for any order.
     * @param orderDigests The order digests (CoW) or Permit2 hashes (UniswapX) to clean up.
     */
    function cleanExpiredOrders(bytes32[] calldata orderDigests) external;
}
