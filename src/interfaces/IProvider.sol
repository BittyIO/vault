// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @title IProvider
 * @notice Interface for all providers.
 * @dev This interface is used to initialize the provider.
 */
interface IProvider {
    /**
     * @notice Initialize the provider.
     * @param newOwner The address of the new owner.
     * @dev Initialize the provider.
     */
    function initialize(address newOwner) external;
}
