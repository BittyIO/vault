// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IAssetManager} from "./IAssetManager.sol";

/**
 * @title Manage the fund of the Trust.
 * @dev Trustee can manage the fund of the Trust, including rebalancing, getting fees, etc.
 */

interface ITrustee {
    /**
     * @notice Change the trustee address.
     * @dev Change the trustee address.
     * @param newTrusteeAddress The new trustee address.
     */
    function changeTrusteeAddress(address newTrusteeAddress) external;

    /**
     * @notice Set the asset manager address.
     * @dev Set the asset manager address.
     * @param assetManagerAddress The address of the asset manager.
     */
    function setAssetManager(address assetManagerAddress) external;

    /**
     * @notice Set the manage fee.
     * @dev Set the manage fee.
     * @param manageFee The manage fee.
     */
    function setManageFee(IAssetManager.ManageFee memory manageFee) external;

    /**
     * @notice Add white listed assets.
     * @dev Add white listed assets.
     * @param assetAddresses The addresses of the assets.
     */
    function addWhiteListedAssets(address[] memory assetAddresses) external;

    /**
     * @notice Remove white listed assets.
     * @dev Remove white listed assets.
     * @param assetAddresses The addresses of the assets.
     */
    function removeWhiteListedAssets(address[] memory assetAddresses) external;
}
