// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

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
}
