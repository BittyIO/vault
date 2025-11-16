// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

/**
 * @title Manage the white listed assets of the BittyVault.
 * @dev BittyVault can manage the white listed assets of the BittyVault, including adding and removing assets.
 */

interface IAssets {
    /**
     * @notice Add a white listed asset to the BittyVault.
     * @dev Add a white listed asset to the BittyVault.
     * @param assetAddress The address of the asset.
     */
    function add(address assetAddress) external;

    /**
     * @notice Remove a white listed asset from the BittyVault.
     * @dev Remove a white listed asset from the BittyVault.
     * @param assetAddress The address of the asset.
     */
    function remove(address assetAddress) external;

    /**
     * @notice Check if an asset is white listed.
     * @dev Check if an asset is white listed.
     * @param assetAddress The address of the asset.
     * @return bool True if the asset is white listed, false otherwise.
     */
    function isWhiteListed(address assetAddress) external view returns (bool);
}
