// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ISubscribe} from "./interfaces/ISubscribe.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {
    AddressZero,
    NotWhiteListed,
    InsufficientBalance,
    TransferFailed,
    AlreadyPremium,
    AlreadyBase,
    SubscriptionNone,
    SubscriptionDowngrade,
    SubscriptionUpgrade,
    InsufficientWithdrawableFee,
    AlreadySubscribed
} from "./interfaces/Errors.sol";
import {IWhiteList} from "./interfaces/IWhiteList.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Subscribe is ISubscribe, Ownable, Initializable {
    using EnumerableSet for EnumerableSet.AddressSet;
    uint256 public constant BASE_FEE = 99;
    uint256 public constant STANDARD_FEE = 199;
    uint256 public constant PREMIUM_FEE = 999;

    address whiteList;
    EnumerableSet.AddressSet private _subscribers;
    mapping(address => ISubscribe.SubscriptionInfo) public subscriptions;

    constructor() {
        transferOwnership(tx.origin);
    }

    function initialize(address whiteListAddress_) external initializer {
        if (whiteListAddress_ == address(0)) {
            revert AddressZero();
        }
        whiteList = whiteListAddress_;
    }

    function subscribe(ISubscribe.Subscription subscription, address stableCoinAddress) external override {
        if (subscriptions[msg.sender].subscription != ISubscribe.Subscription.None) {
            revert AlreadySubscribed();
        }
        if (!IWhiteList(whiteList).isStableCoinWhiteListed(stableCoinAddress)) {
            revert NotWhiteListed();
        }
        subscriptions[msg.sender] = ISubscribe.SubscriptionInfo({
            subscription: subscription, expirationTime: block.timestamp + 365 days, stableCoinAddress: stableCoinAddress
        });
        IERC20Decimals stableCoin = IERC20Decimals(stableCoinAddress);
        uint256 fee = _getFee(subscription) * 10 ** stableCoin.decimals();
        if (IERC20Decimals(stableCoinAddress).balanceOf(msg.sender) < fee) {
            revert InsufficientBalance();
        }
        stableCoin.transferFrom(msg.sender, address(this), fee);
        _subscribers.add(msg.sender);
    }

    function unsubscribe() external override {
        if (subscriptions[msg.sender].subscription == ISubscribe.Subscription.None) {
            revert SubscriptionNone();
        }
        uint256 refundFee = _refundableFee(msg.sender, subscriptions[msg.sender].stableCoinAddress);
        IERC20Decimals stableCoin = IERC20Decimals(subscriptions[msg.sender].stableCoinAddress);
        stableCoin.transfer(msg.sender, refundFee);
        delete subscriptions[msg.sender];
        _subscribers.remove(msg.sender);
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
        IERC20Decimals stableCoin = IERC20Decimals(stableCoinAddress);
        uint256 fee = _getFee(subscription) * 10 ** stableCoin.decimals();
        uint256 refundFee = _refundableFee(msg.sender, stableCoinAddress);
        uint256 totalFee = fee - refundFee;
        if (stableCoin.balanceOf(msg.sender) < totalFee) {
            revert InsufficientBalance();
        }
        subscriptions[msg.sender] = ISubscribe.SubscriptionInfo({
            subscription: subscription, expirationTime: block.timestamp + 365 days, stableCoinAddress: stableCoinAddress
        });
        stableCoin.transferFrom(msg.sender, address(this), totalFee);
    }

    function downgrade(ISubscribe.Subscription subscription) external override {
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
        uint256 downgradedFee =
            _getFee(subscription) * 10 ** IERC20Decimals(subscriptionInfo.stableCoinAddress).decimals();
        if (
            downgradedFee > refundFee
                && IERC20Decimals(subscriptionInfo.stableCoinAddress).balanceOf(msg.sender)
                    < (downgradedFee - refundFee)
        ) {
            revert InsufficientBalance();
        }
        if (downgradedFee < refundFee) {
            IERC20Decimals(subscriptionInfo.stableCoinAddress).transfer(msg.sender, refundFee - downgradedFee);
        } else if (downgradedFee > refundFee) {
            IERC20Decimals(subscriptionInfo.stableCoinAddress)
                .transferFrom(msg.sender, address(this), downgradedFee - refundFee);
        }
        subscriptions[msg.sender] = ISubscribe.SubscriptionInfo({
            subscription: subscription,
            expirationTime: block.timestamp + 365 days,
            stableCoinAddress: subscriptionInfo.stableCoinAddress
        });
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
        uint256 oneYearFee = _getFee(subscriptionInfo.subscription) * 10 ** IERC20Decimals(stableCoinAddress).decimals();
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
        return IERC20Decimals(stableCoinAddress).balanceOf(address(this)) - totalWithdrawableFee;
    }

    function withdrawFee(address stableCoinAddress, uint256 amount, address payable to) external override onlyOwner {
        if (to == address(0)) {
            revert AddressZero();
        }
        uint256 withdrawableFeeForStableCoin = _withdrawableFee(stableCoinAddress);
        if (withdrawableFeeForStableCoin < amount) {
            revert InsufficientWithdrawableFee();
        }
        IERC20Decimals stableCoin = IERC20Decimals(stableCoinAddress);
        if (!stableCoin.transfer(to, amount)) {
            revert TransferFailed();
        }
    }
}
