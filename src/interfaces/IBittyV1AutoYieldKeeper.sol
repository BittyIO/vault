// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

interface IBittyV1AutoYieldKeeper {
    /**
     * @notice Authorises `signer` to sign sweeps until `expiresAt`, or revokes it with 0.
     */
    function setSigner(address signer, uint64 expiresAt) external;

    /**
     * @notice Returns whether `signer` may sign right now.
     */
    function isActiveSigner(address signer) external view returns (bool);

    /**
     * @notice Decodes the keeper signature format `abi.encode(signer, innerSignature)`.
     */
    function decodeSignature(bytes calldata signature) external pure returns (address signer, bytes calldata inner);

    /**
     * @notice Validates a signature from an active signer for a trusted forwarder.
     */
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}
