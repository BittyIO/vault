// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

/**
 * @title Protect the trust.
 * @dev
 *
 */
interface IProtector {
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
     * @notice Replace the trustee if the trustee is not working for trust in good ways.
     * @dev Replace the trustee.
     * @param newTrusteeAddress The address of the new trustee.
     */
    function replaceTrustee(address newTrusteeAddress) external;
}
