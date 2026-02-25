// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {
    ISubscribe,
    AlreadySubscribed,
    AlreadyPremium,
    AlreadyBase,
    SubscriptionNone,
    SubscriptionDowngrade,
    SubscriptionUpgrade,
    StableCoinMismatch,
    InsufficientWithdrawableFee
} from "./interfaces/ISubscribe.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {AddressZero, InsufficientBalance} from "./interfaces/IVault.sol";
import {IWhiteList, NotWhiteListed} from "./interfaces/IWhiteList.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract Subscribe is ISubscribe, Ownable, Initializable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20Metadata;
    uint256 public constant BASE_FEE = 99;
    uint256 public constant STANDARD_FEE = 199;
    uint256 public constant PREMIUM_FEE = 999;

    address private _whiteList;
    EnumerableSet.AddressSet private _subscribers;
    mapping(address => ISubscribe.SubscriptionInfo) public subscriptions;

    constructor() {}

    function initialize(address whiteListAddress_) external initializer {
        if (whiteListAddress_ == address(0)) {
            revert AddressZero();
        }
        _whiteList = whiteListAddress_;
    }

    function subscribe(ISubscribe.Subscription subscription, address stableCoinAddress) external override {
        if (subscription == ISubscribe.Subscription.None) {
            revert SubscriptionNone();
        }
        if (subscriptions[msg.sender].subscription != ISubscribe.Subscription.None) {
            revert AlreadySubscribed();
        }
        if (!IWhiteList(_whiteList).isStableCoinWhiteListed(stableCoinAddress)) {
            revert NotWhiteListed();
        }
        subscriptions[msg.sender] = ISubscribe.SubscriptionInfo({
            subscription: subscription, expirationTime: block.timestamp + 365 days, stableCoinAddress: stableCoinAddress
        });
        IERC20Metadata stableCoin = IERC20Metadata(stableCoinAddress);
        uint256 fee = _getFee(subscription) * 10 ** stableCoin.decimals();
        if (stableCoin.balanceOf(msg.sender) < fee) {
            revert InsufficientBalance();
        }
        stableCoin.safeTransferFrom(msg.sender, address(this), fee);
        _subscribers.add(msg.sender);
    }

    function expiredTime(address user) external view override returns (uint256) {
        return subscriptions[user].expirationTime;
    }

    function renew(uint8 yearCount) external override {
        if (subscriptions[msg.sender].subscription == ISubscribe.Subscription.None) {
            revert SubscriptionNone();
        }
        IERC20Metadata stableCoin = IERC20Metadata(subscriptions[msg.sender].stableCoinAddress);
        uint256 fee = _getFee(subscriptions[msg.sender].subscription) * 10 ** stableCoin.decimals() * yearCount;
        if (stableCoin.balanceOf(msg.sender) < fee) {
            revert InsufficientBalance();
        }
        stableCoin.safeTransferFrom(msg.sender, address(this), fee);
        subscriptions[msg.sender].expirationTime += 365 days * yearCount;
    }

    function unsubscribe() external override {
        if (subscriptions[msg.sender].subscription == ISubscribe.Subscription.None) {
            revert SubscriptionNone();
        }
        uint256 refundFee = _refundableFee(msg.sender, subscriptions[msg.sender].stableCoinAddress);
        IERC20Metadata stableCoin = IERC20Metadata(subscriptions[msg.sender].stableCoinAddress);
        delete subscriptions[msg.sender];
        _subscribers.remove(msg.sender);
        stableCoin.safeTransfer(msg.sender, refundFee);
    }

    function upgrade(ISubscribe.Subscription subscription, address stableCoinAddress) external override {
        ISubscribe.SubscriptionInfo memory subscriptionInfo = subscriptions[msg.sender];
        if (subscriptionInfo.subscription == ISubscribe.Subscription.PREMIUM) {
            revert AlreadyPremium();
        }
        if (subscriptionInfo.subscription == ISubscribe.Subscription.None) {
            revert SubscriptionNone();
        }
        if (subscriptionInfo.subscription >= subscription) {
            revert SubscriptionDowngrade();
        }
        if (subscriptionInfo.stableCoinAddress != stableCoinAddress) {
            revert StableCoinMismatch();
        }
        IERC20Metadata stableCoin = IERC20Metadata(stableCoinAddress);
        uint256 fee = _getFee(subscription) * 10 ** stableCoin.decimals();
        uint256 refundFee = _refundableFee(msg.sender, stableCoinAddress);
        uint256 totalFee = fee - refundFee;
        if (stableCoin.balanceOf(msg.sender) < totalFee) {
            revert InsufficientBalance();
        }
        subscriptions[msg.sender] = ISubscribe.SubscriptionInfo({
            subscription: subscription, expirationTime: block.timestamp + 365 days, stableCoinAddress: stableCoinAddress
        });
        stableCoin.safeTransferFrom(msg.sender, address(this), totalFee);
    }

    function downgrade(ISubscribe.Subscription subscription) external override {
        if (subscription == ISubscribe.Subscription.None) {
            revert SubscriptionNone();
        }
        ISubscribe.SubscriptionInfo memory subscriptionInfo = subscriptions[msg.sender];
        if (subscriptionInfo.subscription == ISubscribe.Subscription.None) {
            revert SubscriptionNone();
        }
        if (subscriptionInfo.subscription == ISubscribe.Subscription.BASE) {
            revert AlreadyBase();
        }
        if (subscriptionInfo.subscription <= subscription) {
            revert SubscriptionUpgrade();
        }
        uint256 refundFee = _refundableFee(msg.sender, subscriptionInfo.stableCoinAddress);
        IERC20Metadata stableCoin = IERC20Metadata(subscriptionInfo.stableCoinAddress);
        uint256 downgradedFee = _getFee(subscription) * 10 ** stableCoin.decimals();
        if (downgradedFee > refundFee && stableCoin.balanceOf(msg.sender) < (downgradedFee - refundFee)) {
            revert InsufficientBalance();
        }

        subscriptions[msg.sender] = ISubscribe.SubscriptionInfo({
            subscription: subscription,
            expirationTime: block.timestamp + 365 days,
            stableCoinAddress: subscriptionInfo.stableCoinAddress
        });

        if (downgradedFee < refundFee) {
            stableCoin.safeTransfer(msg.sender, refundFee - downgradedFee);
        } else if (downgradedFee > refundFee) {
            stableCoin.safeTransferFrom(msg.sender, address(this), downgradedFee - refundFee);
        }
    }

    function subscriptionLevel(address user) external view override returns (ISubscribe.Subscription) {
        ISubscribe.SubscriptionInfo memory subscriptionInfo = subscriptions[user];
        if (subscriptionInfo.expirationTime < block.timestamp) {
            return ISubscribe.Subscription.None;
        }
        return subscriptionInfo.subscription;
    }

    function _getFee(ISubscribe.Subscription subscription) internal pure returns (uint256) {
        if (subscription == ISubscribe.Subscription.BASE) {
            return BASE_FEE;
        }
        if (subscription == ISubscribe.Subscription.STANDARD) {
            return STANDARD_FEE;
        }
        return PREMIUM_FEE;
    }

    function refundableFee(address subscriber, address stableCoinAddress) external view override returns (uint256) {
        return _refundableFee(subscriber, stableCoinAddress);
    }

    function _refundableFee(address subscriber, address stableCoinAddress) internal view returns (uint256) {
        ISubscribe.SubscriptionInfo memory subscriptionInfo = subscriptions[subscriber];
        if (subscriptionInfo.subscription == ISubscribe.Subscription.None) {
            return 0;
        }
        if (subscriptionInfo.stableCoinAddress != stableCoinAddress) {
            return 0;
        }
        if (subscriptionInfo.expirationTime <= block.timestamp) {
            return 0;
        }
        IERC20Metadata stableCoin = IERC20Metadata(stableCoinAddress);
        uint256 oneYearFee = _getFee(subscriptionInfo.subscription) * 10 ** stableCoin.decimals();
        return oneYearFee * (subscriptionInfo.expirationTime - block.timestamp) / 365 days;
    }

    function withdrawableFee(address stableCoinAddress) external view override returns (uint256) {
        return _withdrawableFee(stableCoinAddress);
    }

    function _withdrawableFee(address stableCoinAddress) internal view returns (uint256) {
        uint256 totalWithdrawableFee = 0;
        for (uint256 i = 0; i < _subscribers.length(); i++) {
            address subscriber = _subscribers.at(i);
            uint256 refundFee = _refundableFee(subscriber, stableCoinAddress);
            if (refundFee > 0) {
                totalWithdrawableFee += refundFee;
            }
        }
        return IERC20Metadata(stableCoinAddress).balanceOf(address(this)) - totalWithdrawableFee;
    }

    function withdrawFee(address stableCoinAddress, uint256 amount, address payable to) external override onlyOwner {
        if (to == address(0)) {
            revert AddressZero();
        }
        uint256 withdrawableFeeForStableCoin = _withdrawableFee(stableCoinAddress);
        if (withdrawableFeeForStableCoin < amount) {
            revert InsufficientWithdrawableFee();
        }
        IERC20Metadata stableCoin = IERC20Metadata(stableCoinAddress);
        stableCoin.safeTransfer(to, amount);
    }
}
