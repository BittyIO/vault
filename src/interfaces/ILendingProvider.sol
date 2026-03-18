// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IProvider} from "./IProvider.sol";

interface ILendingProvider is IProvider {
    /**
     * @notice Supply the asset to the lending provider.
     * @dev Supply the asset to the lending provider.
     * @param asset The address of the asset.
     * @param amount The amount of the asset.
     */
    function supply(address asset, uint256 amount) external payable;

    /**
     * @notice Withdraw the asset from the lending provider.
     * @dev Withdraw the asset from the lending provider.
     * @param asset The address of the asset.
     * @param amount The amount of the asset.
     */
    function withdraw(address asset, uint256 amount) external;

    /**
     * @notice Get the lending balance of the asset.
     * @dev Get the lending balance of the asset.
     * @param asset The address of the asset.
     * @return The lending balance of the asset.
     */
    function getLendingBalance(address asset) external view returns (uint256);
}
