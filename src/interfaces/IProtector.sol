// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

/**
 * @title Protect the trust.
 * @dev 
 **/
interface IProtector {

    /**
     * @notice Set the protector.
     * @dev Set the protector.
     * @param protectorAddress The address of the protector.
     */
    function setProtector(address protectorAddress) external;

    /**
     * @notice Pause the fund management.
     * @dev Pause the fund management.
     */
    function pauseFundManagement() external;

    /**
     * @notice Resume the fund management.
     * @dev Resume the fund management.
     */
    function resumeFundManagement() external;

    /**
     * @notice Replace the fund manager if the fund manager is not working for trust in good ways.
     * @dev Replace the fund manager.
     * @param newFundManagerAddress The address of the new fund manager.
     */
    function replaceFundManager(address newFundManagerAddress) external;
    
}