// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Subscription} from "subscription-contracts/src/Subscription.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Deploys the real Subscription contract and subscribes vaults via `subscribeFor()`.
abstract contract SubscriptionTestSetup is Test {
    uint256 internal constant SUBSCRIPTION_FEE = 1;

    function deploySubscription(address whiteList) internal returns (Subscription) {
        Subscription subscription = new Subscription();
        vm.startPrank(tx.origin);
        subscription.initialize(whiteList, SUBSCRIPTION_FEE);
        subscription.setSubscriptionFeeReceiver(makeAddr("subscriptionFeeReceiver"));
        vm.stopPrank();
        return subscription;
    }

    /// @notice Subscribe `vault` on-chain; `payer` funds the vault then the vault pays the fee.
    function subscribeVault(
        Subscription subscription,
        address vault,
        address payer,
        address stableCoin,
        uint8 yearCount
    ) internal {
        uint256 fee = SUBSCRIPTION_FEE * 10 ** IERC20Metadata(stableCoin).decimals() * yearCount;
        deal(stableCoin, payer, fee);
        vm.prank(payer);
        IERC20(stableCoin).transfer(vault, fee);
        vm.startPrank(vault);
        IERC20(stableCoin).approve(address(subscription), fee);
        subscription.subscribeFor(stableCoin, vault, yearCount);
        vm.stopPrank();
    }
}
