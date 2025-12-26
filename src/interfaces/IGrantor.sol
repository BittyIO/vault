// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

/**
 * @title Create and set the rules of the Trust.
 * @dev
 */
interface IGrantor {
    /**
     * @notice Set the grantor.
     * @dev Set the grantor.
     * @param grantorAddress The address of the grantor.
     */
    function changeGrantorAddress(address grantorAddress) external;
}
