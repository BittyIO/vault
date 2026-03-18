// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/// @title CoW Protocol GPv2 Settlement Interface
/// @notice Minimal interface for CoW Protocol settlement (PreSign, domain separator)
interface IGPv2Settlement {
    /// @notice Domain separator for EIP-712 order signing
    function domainSeparator() external view returns (bytes32);

    /// @notice Pre-sign an order for CoW Protocol
    /// @dev Caller must be the order owner. Order must be submitted to CoW API separately.
    /// @param orderUid The unique identifier of the order (56 bytes: digest + owner + validTo)
    /// @param signed True to enable the order for trading, false to revoke
    function setPreSignature(bytes calldata orderUid, bool signed) external;
}
