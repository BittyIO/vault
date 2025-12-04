// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";

import {ISubscribe} from "../src/interfaces/ISubscribe.sol";
import {Subscribe} from "../src/Subscribe.sol";
import {IWhiteList} from "../src/interfaces/IWhiteList.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {
    AddressZero,
    NotWhiteListed,
    InsufficientBalance,
    AlreadyPremium,
    AlreadyBase,
    SubscriptionNone,
    SubscriptionDowngrade,
    SubscriptionUpgrade,
    InsufficientWithdrawableFee,
    AlreadySubscribed
} from "../src/interfaces/Errors.sol";

contract SubscribeTest is Test {
    address public user;
    Subscribe public subscribe;
    address public feeReceiver;
    address public whiteList;
    MockERC20 public mockStableCoin;
    MockERC20 public mockStableCoin2;

    function setUp() public {
        user = makeAddr("alice");
        feeReceiver = makeAddr("feeReceiver");
        whiteList = address(new WhiteList());
        mockStableCoin = new MockERC20("StableCoin", "USDT", 6);
        subscribe = new Subscribe();
        vm.prank(tx.origin);
        address[] memory stableCoins = new address[](2);
        stableCoins[0] = address(mockStableCoin);
        stableCoins[1] = address(mockStableCoin2);
        IWhiteList(whiteList).addStableCoins(stableCoins);
    }

    function test_InitializeFailedWhenWhiteListIsZeroAddress() public {
        vm.prank(tx.origin);
        vm.expectRevert(AddressZero.selector);
        subscribe.initialize(address(0));
    }

    function test_SubscribeFailedWhenStableCoinNotWhiteListed() public {
        vm.prank(tx.origin);
        subscribe.initialize(whiteList);
        vm.prank(user);
        address invalidStableCoin = makeAddr("invalidStableCoin");
        vm.expectRevert(NotWhiteListed.selector);
        subscribe.subscribe(ISubscribe.Subscription.BASE, invalidStableCoin);
    }

    function test_SubscribeFailedWhenBalanceNotEnough() public {
        subscribe.initialize(whiteList);
        vm.prank(user);
        uint256 baseFee = subscribe.BASE_FEE();
        uint256 decimals = mockStableCoin.decimals();
        uint256 requiredFee = baseFee * (10 ** decimals);
        deal(address(mockStableCoin), user, requiredFee - 1);
        mockStableCoin.approve(address(subscribe), requiredFee - 1);
        vm.expectRevert(InsufficientBalance.selector);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
    }

    function test_SubscribeBaseSuccess() public {
        subscribe.initialize(whiteList);
        uint256 baseFee = subscribe.BASE_FEE();
        uint256 decimals = mockStableCoin.decimals();
        uint256 requiredFee = baseFee * (10 ** decimals);
        deal(address(mockStableCoin), user, requiredFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), requiredFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
        assertEq(uint8(subscribe.subscriptionLevel(user)), uint8(ISubscribe.Subscription.BASE));
        assertEq(mockStableCoin.balanceOf(address(subscribe)), requiredFee);
        assertEq(mockStableCoin.balanceOf(user), 0);
    }

    function test_SubscribeBaseFailedWhenAlreadySubscribed() public {
        subscribe.initialize(whiteList);
        vm.prank(user);
        uint256 baseFee = subscribe.BASE_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, baseFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), 2 * baseFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
        vm.prank(user);
        vm.expectRevert(AlreadySubscribed.selector);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
    }

    function test_SubscribeStandardSuccess() public {
        subscribe.initialize(whiteList);
        uint256 standardFee = subscribe.STANDARD_FEE();
        uint256 decimals = mockStableCoin.decimals();
        uint256 requiredFee = standardFee * (10 ** decimals);
        deal(address(mockStableCoin), user, requiredFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), requiredFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.STANDARD, address(mockStableCoin));
        assertEq(uint8(subscribe.subscriptionLevel(user)), uint8(ISubscribe.Subscription.STANDARD));
        assertEq(mockStableCoin.balanceOf(address(subscribe)), requiredFee);
        assertEq(mockStableCoin.balanceOf(user), 0);
    }

    function test_SubscribePremiumSuccess() public {
        subscribe.initialize(whiteList);
        uint256 premiumFee = subscribe.PREMIUM_FEE();
        uint256 decimals = mockStableCoin.decimals();
        uint256 requiredFee = premiumFee * (10 ** decimals);
        deal(address(mockStableCoin), user, requiredFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), requiredFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.PREMIUM, address(mockStableCoin));
        assertEq(uint8(subscribe.subscriptionLevel(user)), uint8(ISubscribe.Subscription.PREMIUM));
        assertEq(mockStableCoin.balanceOf(address(subscribe)), requiredFee);
        assertEq(mockStableCoin.balanceOf(user), 0);
    }

    function test_UpgradeFailedWhenNotSubscribed() public {
        subscribe.initialize(whiteList);
        vm.prank(user);
        vm.expectRevert(SubscriptionNone.selector);
        subscribe.upgrade(ISubscribe.Subscription.BASE, address(mockStableCoin));
    }

    function test_UpgradeFailedWhenSubscriptionDowngrade() public {
        subscribe.initialize(whiteList);
        uint256 standardFee = subscribe.STANDARD_FEE() * (10 ** mockStableCoin.decimals());
        vm.prank(user);
        deal(address(mockStableCoin), user, standardFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), standardFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.STANDARD, address(mockStableCoin));
        vm.prank(user);
        vm.expectRevert(SubscriptionDowngrade.selector);
        subscribe.upgrade(ISubscribe.Subscription.BASE, address(mockStableCoin));
    }

    function test_UpgradeFailedWhenAlreadyPremium() public {
        subscribe.initialize(whiteList);
        uint256 premiumFee = subscribe.PREMIUM_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, premiumFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), premiumFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.PREMIUM, address(mockStableCoin));
        vm.prank(user);
        vm.expectRevert(AlreadyPremium.selector);
        subscribe.upgrade(ISubscribe.Subscription.PREMIUM, address(mockStableCoin));
    }

    function test_UpgradeFailedWhenInsufficientBalance() public {
        subscribe.initialize(whiteList);
        uint256 standardFee = subscribe.STANDARD_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, subscribe.PREMIUM_FEE() * (10 ** mockStableCoin.decimals()) - 1);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), standardFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.STANDARD, address(mockStableCoin));
        vm.prank(user);
        vm.expectRevert(InsufficientBalance.selector);
        subscribe.upgrade(ISubscribe.Subscription.PREMIUM, address(mockStableCoin));
    }

    function test_UpgradeSuccess() public {
        subscribe.initialize(whiteList);
        uint256 premiumFee = subscribe.PREMIUM_FEE() * (10 ** mockStableCoin.decimals());
        uint256 standardFee = subscribe.STANDARD_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, premiumFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), standardFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.STANDARD, address(mockStableCoin));

        uint256 upgradeDifference = premiumFee - standardFee;
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), upgradeDifference);
        vm.prank(user);
        subscribe.upgrade(ISubscribe.Subscription.PREMIUM, address(mockStableCoin));
        assertEq(uint8(subscribe.subscriptionLevel(user)), uint8(ISubscribe.Subscription.PREMIUM));
        assertEq(mockStableCoin.balanceOf(address(subscribe)), premiumFee);
        assertEq(mockStableCoin.balanceOf(user), 0);
    }

    function test_DowngradeFailedWhenNotSubscribed() public {
        subscribe.initialize(whiteList);
        vm.prank(user);
        vm.expectRevert(SubscriptionNone.selector);
        subscribe.downgrade(ISubscribe.Subscription.BASE);
    }

    function test_DowngradeFailedWhenSubscriptionUpgrade() public {
        subscribe.initialize(whiteList);
        uint256 premiumFee = subscribe.PREMIUM_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, premiumFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), premiumFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.STANDARD, address(mockStableCoin));
        vm.prank(user);
        vm.expectRevert(SubscriptionUpgrade.selector);
        subscribe.downgrade(ISubscribe.Subscription.PREMIUM);
    }

    function test_DowngradeFailedWhenSubscriptionBase() public {
        subscribe.initialize(whiteList);
        uint256 baseFee = subscribe.BASE_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, baseFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), baseFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
        vm.prank(user);
        vm.expectRevert(AlreadyBase.selector);
        subscribe.downgrade(ISubscribe.Subscription.BASE);
    }

    function test_DowngradeFailedWhenInsufficientBalance() public {
        subscribe.initialize(whiteList);
        uint256 premiumFee = subscribe.PREMIUM_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, premiumFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), premiumFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.PREMIUM, address(mockStableCoin));
        vm.warp(block.timestamp + 360 days);
        vm.prank(user);
        vm.expectRevert(InsufficientBalance.selector);
        subscribe.downgrade(ISubscribe.Subscription.BASE);
    }

    function test_DowngradeSuccessUserGetsRefund() public {
        subscribe.initialize(whiteList);
        uint256 premiumFee = subscribe.PREMIUM_FEE() * (10 ** mockStableCoin.decimals());
        uint256 baseFee = subscribe.BASE_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, premiumFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), premiumFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.PREMIUM, address(mockStableCoin));

        uint256 usingDays = 10 days;
        vm.warp(block.timestamp + usingDays);

        uint256 remainingDays = 365 days - usingDays;
        uint256 refundFee = premiumFee * remainingDays / 365 days;
        uint256 downgradedFee = baseFee;
        uint256 expectedRefund = refundFee - downgradedFee;
        uint256 userBalanceBefore = mockStableCoin.balanceOf(user);

        vm.prank(user);
        subscribe.downgrade(ISubscribe.Subscription.BASE);

        assertEq(uint8(subscribe.subscriptionLevel(user)), uint8(ISubscribe.Subscription.BASE));
        assertEq(mockStableCoin.balanceOf(user), userBalanceBefore + expectedRefund);
        assertEq(mockStableCoin.balanceOf(address(subscribe)), premiumFee - expectedRefund);
    }

    function test_DowngradeSuccessUserPaysDifference() public {
        subscribe.initialize(whiteList);
        uint256 premiumFee = subscribe.PREMIUM_FEE() * (10 ** mockStableCoin.decimals());
        uint256 baseFee = subscribe.BASE_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, premiumFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), premiumFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.PREMIUM, address(mockStableCoin));

        uint256 usingDays = 350 days;
        vm.warp(block.timestamp + usingDays);

        uint256 remainingDays = 365 days - usingDays;
        uint256 refundFee = premiumFee * remainingDays / 365 days;
        uint256 downgradedFee = baseFee;

        uint256 expectedPayment = downgradedFee - refundFee;
        uint256 userBalanceBefore = mockStableCoin.balanceOf(user);

        deal(address(mockStableCoin), user, userBalanceBefore + expectedPayment);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), expectedPayment);

        vm.prank(user);
        subscribe.downgrade(ISubscribe.Subscription.BASE);

        assertEq(uint8(subscribe.subscriptionLevel(user)), uint8(ISubscribe.Subscription.BASE));
        assertEq(mockStableCoin.balanceOf(user), userBalanceBefore);
        assertEq(mockStableCoin.balanceOf(address(subscribe)), premiumFee - refundFee + downgradedFee);
    }

    function test_UnsubscribeFailedWhenSubscriptionNone() public {
        subscribe.initialize(whiteList);
        vm.expectRevert(SubscriptionNone.selector);
        vm.prank(user);
        subscribe.unsubscribe();
    }

    function test_QueryRefundableFee() public {
        subscribe.initialize(whiteList);
        uint256 baseFee = subscribe.BASE_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, baseFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), baseFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
        uint256 subscriptionTimestamp = block.timestamp;
        uint256 usingDays = 180 days;
        vm.warp(subscriptionTimestamp + usingDays);
        uint256 refundableFee = subscribe.refundableFee(user, address(mockStableCoin));
        uint256 remainingDays = 365 days - usingDays;
        uint256 expectedRefund = baseFee * remainingDays / 365 days;
        assertEq(refundableFee, expectedRefund);
        uint256 refundableFee2 = subscribe.refundableFee(user, address(mockStableCoin2));
        assertEq(refundableFee2, 0);
    }

    function test_WithdrawFeeFailedWhenAddressZero() public {
        subscribe.initialize(whiteList);
        vm.prank(tx.origin);
        vm.expectRevert(AddressZero.selector);
        subscribe.withdrawFee(address(mockStableCoin), 0, payable(address(0)));
    }

    function test_WithdrawableFee() public {
        subscribe.initialize(whiteList);
        uint256 baseFee = subscribe.BASE_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, baseFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), baseFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
        address bob = makeAddr("bob");
        deal(address(mockStableCoin), bob, baseFee);
        vm.prank(bob);
        mockStableCoin.approve(address(subscribe), baseFee);
        vm.prank(bob);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
        uint256 withdrawableFee = subscribe.withdrawableFee(address(mockStableCoin));
        assertEq(withdrawableFee, 0);
        uint256 subscriptionTimestamp = block.timestamp;
        uint256 usingDays = 180 days;
        vm.warp(subscriptionTimestamp + usingDays);
        withdrawableFee = subscribe.withdrawableFee(address(mockStableCoin));
        uint256 remainingDays = 365 days - usingDays;
        uint256 refundableFeePerUser = baseFee * remainingDays / 365 days;
        uint256 totalRefundableFee = 2 * refundableFeePerUser;
        uint256 totalBalance = 2 * baseFee;
        uint256 expectedWithdrawableFee = totalBalance - totalRefundableFee;
        assertEq(withdrawableFee, expectedWithdrawableFee);
    }

    function test_WithdrawFeeFailedWhenNotFromOwner() public {
        subscribe.initialize(whiteList);
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        subscribe.withdrawFee(address(mockStableCoin), 0, payable(user));
    }

    function test_WithdrawFeeFailedWhenInsufficientWithdrawableFee() public {
        subscribe.initialize(whiteList);
        vm.expectRevert(InsufficientWithdrawableFee.selector);
        vm.prank(tx.origin);
        subscribe.withdrawFee(address(mockStableCoin), 1, payable(user));
    }

    function test_WithdrawFeeSuccess() public {
        subscribe.initialize(whiteList);
        uint256 baseFee = subscribe.BASE_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, baseFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), baseFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
        vm.warp(block.timestamp + 365 days);
        vm.prank(tx.origin);
        address payable to = payable(makeAddr("to"));
        subscribe.withdrawFee(address(mockStableCoin), baseFee, to);
        assertEq(mockStableCoin.balanceOf(to), baseFee);
        assertEq(mockStableCoin.balanceOf(user), 0);
        assertEq(mockStableCoin.balanceOf(address(subscribe)), 0);
    }

    function test_UnsubscribeSuccess() public {
        subscribe.initialize(whiteList);
        uint256 baseFee = subscribe.BASE_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, baseFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), baseFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
        uint256 usingDays = 180 days;
        vm.warp(block.timestamp + usingDays);
        vm.prank(user);
        subscribe.unsubscribe();
        assertEq(uint8(subscribe.subscriptionLevel(user)), uint8(ISubscribe.Subscription.None));
        assertEq(subscribe.refundableFee(user, address(mockStableCoin)), 0);
        uint256 remainingDays = 365 days - usingDays;
        uint256 expectedRefundFee = baseFee * remainingDays / 365 days;
        uint256 expectedUsedFee = baseFee - expectedRefundFee;
        assertEq(mockStableCoin.balanceOf(user), expectedRefundFee);
        assertEq(mockStableCoin.balanceOf(address(subscribe)), expectedUsedFee);
    }

    function test_RenewFailedWhenNotSubscribed() public {
        subscribe.initialize(whiteList);
        vm.prank(user);
        vm.expectRevert(SubscriptionNone.selector);
        subscribe.renew(1);
    }

    function test_RenewFailedWhenInsufficientBalance() public {
        subscribe.initialize(whiteList);
        uint256 baseFee = subscribe.BASE_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, baseFee * 2 - 1);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), baseFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
        mockStableCoin.approve(address(subscribe), baseFee);
        vm.expectRevert(InsufficientBalance.selector);
        vm.prank(user);
        subscribe.renew(1);
    }

    function test_GetExpiredTime() public {
        subscribe.initialize(whiteList);
        uint256 baseFee = subscribe.BASE_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, baseFee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), baseFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
        assertEq(subscribe.expiredTime(user), block.timestamp + 365 days);
    }

    function test_RenewSuccess() public {
        subscribe.initialize(whiteList);
        uint256 baseFee = subscribe.BASE_FEE() * (10 ** mockStableCoin.decimals());
        deal(address(mockStableCoin), user, baseFee * 2);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), baseFee);
        vm.prank(user);
        subscribe.subscribe(ISubscribe.Subscription.BASE, address(mockStableCoin));
        uint256 originalExpirationTime = subscribe.expiredTime(user);
        vm.warp(block.timestamp + 366 days);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), baseFee);
        vm.prank(user);
        subscribe.renew(1);
        assertEq(uint8(subscribe.subscriptionLevel(user)), uint8(ISubscribe.Subscription.BASE));
        assertEq(subscribe.expiredTime(user), originalExpirationTime + 365 days);
        assertEq(mockStableCoin.balanceOf(address(subscribe)), baseFee * 2);
        assertEq(mockStableCoin.balanceOf(user), 0);
    }
}
