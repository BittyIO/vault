// SPDX-License-Identifier: AGPL-3.0-only
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
     * @notice Ping the trustee to make sure the trustee is still alive.
     * @dev Ping the trustee to make sure the trustee is still alive.
     * This is used to check if the trustee is still alive.
     * If the trustee is not alive, the grantor or the beneficiary can set another trustee.
     */
    function trusteePing() external;
}
