// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IAssetManager} from "./IAssetManager.sol";
/**
 * @title Manage the fund of the Trust.
 * @dev Trustee can manage the fund of the Trust, including rebalancing, getting fees, etc.
 */

interface ITrustee is IAssetManager {
    error BaseFeeDurationNotMet();

    struct TrusteeFee {
        /**
         *
         * @param baseFeeAmount The base fee amount.
         * @dev The base fee amount, if isBaseFeePercentage is true, this is 1 / 10000 as unit.
         */
        uint256 baseFeeAmount;
        /**
         * @dev The base fee duration.
         * @param baseFeeDuration The base fee duration.
         */
        uint256 baseFeeDuration;
        /**
         * @dev Whether the base fee is a percentage.
         * @param isBaseFeePercentage Whether the base fee is a percentage.
         */
        bool isBaseFeePercentage;
    }

    /**
     * @notice Change the trustee address.
     * @dev Change the trustee address.
     * @param newTrusteeAddress The new trustee address.
     */
    function changeTrusteeAddress(address newTrusteeAddress) external;

    /**
     * @notice Get the trustee base fee.
     * @dev Get the trustee base fee.
     */
    function getTrusteeBaseFee() external;
}
