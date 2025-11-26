// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

interface ISubscribe {
    enum Subscription {
        None,
        BASE,
        STANDARD,
        PREMIUM
    }

    struct SubscriptionInfo {
        Subscription subscription;
        uint256 expirationTime;
        address stableCoinAddress;
    }

    /**
     * @notice Subscribe to a subscription.
     * @dev Subscribe to a subscription.
     */
    function subscribe(Subscription subscription, address stableCoinAddress) external;

    /**
     * @notice Unsubscribe from msg.sender.
     * @dev Unsubscribe from msg.sender.
     */
    function unsubscribe() external;

    /**
     * @notice Upgrade to a higher subscription.
     * @dev Upgrade to a higher subscription.
     * @param subscription The subscription to upgrade to.
     */
    function upgrade(Subscription subscription, address stableCoinAddress) external;

    /**
     * @notice Downgrade to a lower subscription.
     * @dev Downgrade to a lower subscription.
     * @param subscription The subscription to downgrade to.
     */
    function downgrade(Subscription subscription) external;

    /**
     * @notice Check if a user is subscribed.
     * @dev Check if a user is subscribed.
     * @param user The address to check if is subscribed.
     * @return Subscription The subscription level of the user.
     */
    function subscriptionLevel(address user) external view returns (Subscription);

    /**
     * @notice Check how much subscription fee is refundable.
     * @dev Check how much subscription fee is refundable for msg.sender.
     * @return uint256 The refundable fee for msg.sender.
     */
    function refundableFee(address subscriber, address stableCoinAddress) external view returns (uint256);

    /**
     * @notice Check how much subscription fee is withdrawable.
     * @dev Check how much subscription fee is withdrawable for msg.sender.
     * @return uint256 The withdrawable fee for msg.sender.
     */
    function withdrawableFee(address stableCoinAddress) external view returns (uint256);

    /**
     * @notice Withdraw the fee to the address.
     * @dev Withdraw the fee to the address.
     * @param stableCoinAddress The address of the stable coin.
     * @param amount The amount of the fee to withdraw.
     * @param to The address to withdraw the fee to.
     */
    function withdrawFee(address stableCoinAddress, uint256 amount, address payable to) external;
}
