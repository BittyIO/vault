// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

/**
 * @title The beneficiary of the Trust.
 * @dev
 */
interface IBeneficiary {
    /**
     * @notice only works if beneficiary address is not set.
     * @dev only works for beneficiary to change address.
     * @param newBeneficiaryAddress new beneficiary address
     */
    function changeBeneficiaryAddress(address newBeneficiaryAddress) external;
}
