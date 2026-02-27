// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

interface ISubscribe {
    /**
     * @notice Set the subscription fee receiver.
     * @dev Set the subscription fee receiver.
     * @param subscriptionFeeReceiver The address of the subscription fee receiver.
     */
    function setSubscriptionFeeReceiver(address subscriptionFeeReceiver) external;

    /**
     * @notice Subscribe to a subscription.
     * @dev Subscribe to a subscription.
     * @param stableCoinAddress The address of the stable coin.
     * @param yearCount The number of years to subscribe.
     */
    function subscribe(address stableCoinAddress, uint8 yearCount) external;

    /**
     * @notice Check the expired time of the subscription.
     * @dev Check the expired time of the subscription.
     * @param user The address to check the expired time of the subscription.
     * @return uint256 The expired time of the subscription.
     */
    function getExpirationTime(address user) external view returns (uint256);
}
