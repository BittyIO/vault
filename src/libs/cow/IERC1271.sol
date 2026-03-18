// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/// @title EIP-1271 Smart Contract Signature Verification
/// @notice Interface for CoW Protocol EIP-1271 order signing
interface IERC1271 {
    /// @notice Verifies a signature for the given hash
    /// @param hash The hash that was signed
    /// @param signature The signature to verify
    /// @return magicValue Must return MAGICVALUE (0x1626ba7e) if the signature is valid
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
}
