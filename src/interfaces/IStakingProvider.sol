// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProvider} from "./IProvider.sol";

error UnstakeMoreThanStaked();

/**
 * @title IStakingProvider
 * @notice Interface for staking providers.
 * @dev This interface is used to stake and unstake the asset.
 */
interface IStakingProvider is IProvider {
    /**
     * @notice Stake the asset to the staking provider.
     * @dev Stake the asset to the staking provider.
     * @param amount The amount of the asset.
     */
    function stake(uint256 amount) external payable;

    /**
     * @notice Get the staking balance.
     * @dev Get the staking balance.
     * @return The staking balance.
     */
    function getStakingBalance() external view returns (uint256);

    /**
     * @notice Unstake the asset from the staking provider.
     * @dev Unstake the asset from the staking provider.
     * @param amount The amount of the asset.
     */
    function unstake(uint256 amount) external;

    /**
     * @notice Get the unstake request ids.
     * @dev Get the unstake request ids.
     * @return The unstake request ids.
     */
    function getUnstakeRequestIds() external view returns (uint256[] memory);

    /**
     * @notice Claim the asset from the staking provider.
     * @dev Claim the asset from the staking provider.
     * @param requestIds The request ids to claim.
     */
    function claim(uint256[] memory requestIds) external;
}
