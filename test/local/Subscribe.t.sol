// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";

import {Subscribe} from "../../src/Subscribe.sol";
import {IWhiteList, NotWhiteListed} from "../../src/interfaces/IWhiteList.sol";
import {WhiteList} from "../../src/WhiteList.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {AddressZero, InsufficientBalance} from "../../src/interfaces/IVault.sol";

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
        mockStableCoin2 = new MockERC20("StableCoin2", "USDC", 6);
        subscribe = new Subscribe();
        subscribe.initialize(whiteList);
        subscribe.setSubscriptionFeeReceiver(feeReceiver);

        address[] memory stableCoins = new address[](2);
        stableCoins[0] = address(mockStableCoin);
        stableCoins[1] = address(mockStableCoin2);
        vm.prank(tx.origin);
        IWhiteList(whiteList).addStableCoins(stableCoins);
    }

    function test_InitializeFailedWhenWhiteListIsZeroAddress() public {
        Subscribe sub = new Subscribe();
        vm.expectRevert(AddressZero.selector);
        sub.initialize(address(0));
    }

    function test_SetSubscriptionFeeReceiverFailedWhenAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        subscribe.setSubscriptionFeeReceiver(address(0));
    }

    function test_SetSubscriptionFeeReceiverFailedWhenNotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        subscribe.setSubscriptionFeeReceiver(makeAddr("newReceiver"));
    }

    function test_SubscribeFailedWhenStableCoinNotWhiteListed() public {
        address invalidStableCoin = makeAddr("invalidStableCoin");
        uint256 fee = subscribe.SUBSCRIPTION_FEE() * (10 ** mockStableCoin.decimals()) * 1;
        deal(address(mockStableCoin), user, fee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), fee);
        vm.prank(user);
        vm.expectRevert(NotWhiteListed.selector);
        subscribe.subscribe(invalidStableCoin, 1);
    }

    function test_SubscribeFailedWhenBalanceNotEnough() public {
        uint256 fee = subscribe.SUBSCRIPTION_FEE() * (10 ** mockStableCoin.decimals()) * 1;
        deal(address(mockStableCoin), user, fee - 1);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), fee - 1);
        vm.prank(user);
        vm.expectRevert(InsufficientBalance.selector);
        subscribe.subscribe(address(mockStableCoin), 1);
    }

    function test_SubscribeSuccess() public {
        uint256 fee = subscribe.SUBSCRIPTION_FEE() * (10 ** mockStableCoin.decimals()) * 1;
        deal(address(mockStableCoin), user, fee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), fee);
        vm.prank(user);
        subscribe.subscribe(address(mockStableCoin), 1);

        assertEq(subscribe.getExpirationTime(user), block.timestamp + 365 days);
        assertEq(mockStableCoin.balanceOf(feeReceiver), fee);
        assertEq(mockStableCoin.balanceOf(user), 0);
    }

    function test_SubscribeSuccess_MultipleYears() public {
        uint8 yearCount = 2;
        uint256 fee = subscribe.SUBSCRIPTION_FEE() * (10 ** mockStableCoin.decimals()) * yearCount;
        deal(address(mockStableCoin), user, fee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), fee);
        vm.prank(user);
        subscribe.subscribe(address(mockStableCoin), yearCount);

        assertEq(subscribe.getExpirationTime(user), block.timestamp + 365 days * yearCount);
        assertEq(mockStableCoin.balanceOf(feeReceiver), fee);
        assertEq(mockStableCoin.balanceOf(user), 0);
    }

    function test_SubscribeSuccess_RenewalBeforeExpiry() public {
        uint256 fee = subscribe.SUBSCRIPTION_FEE() * (10 ** mockStableCoin.decimals()) * 1;
        deal(address(mockStableCoin), user, fee * 2);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), fee * 2);
        vm.prank(user);
        subscribe.subscribe(address(mockStableCoin), 1);

        uint256 expirationAfterFirst = subscribe.getExpirationTime(user);
        vm.warp(block.timestamp + 100 days);

        vm.prank(user);
        subscribe.subscribe(address(mockStableCoin), 1);

        assertEq(subscribe.getExpirationTime(user), expirationAfterFirst + 365 days);
        assertEq(mockStableCoin.balanceOf(feeReceiver), fee * 2);
    }

    function test_SubscribeSuccess_AfterExpiry() public {
        uint256 fee = subscribe.SUBSCRIPTION_FEE() * (10 ** mockStableCoin.decimals()) * 1;
        deal(address(mockStableCoin), user, fee * 2);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), fee * 2);
        vm.prank(user);
        subscribe.subscribe(address(mockStableCoin), 1);

        vm.warp(block.timestamp + 366 days);

        vm.prank(user);
        subscribe.subscribe(address(mockStableCoin), 1);

        assertEq(subscribe.getExpirationTime(user), block.timestamp + 365 days);
        assertEq(mockStableCoin.balanceOf(feeReceiver), fee * 2);
    }

    function test_GetExpirationTime() public {
        assertEq(subscribe.getExpirationTime(user), 0);

        uint256 fee = subscribe.SUBSCRIPTION_FEE() * (10 ** mockStableCoin.decimals()) * 1;
        deal(address(mockStableCoin), user, fee);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), fee);
        vm.prank(user);
        subscribe.subscribe(address(mockStableCoin), 1);

        assertEq(subscribe.getExpirationTime(user), block.timestamp + 365 days);
    }

    function test_SubscribeSuccess_DifferentStableCoins() public {
        uint256 fee1 = subscribe.SUBSCRIPTION_FEE() * (10 ** mockStableCoin.decimals()) * 1;
        uint256 fee2 = subscribe.SUBSCRIPTION_FEE() * (10 ** mockStableCoin2.decimals()) * 1;
        deal(address(mockStableCoin), user, fee1);
        deal(address(mockStableCoin2), user, fee2);
        vm.prank(user);
        mockStableCoin.approve(address(subscribe), fee1);
        vm.prank(user);
        mockStableCoin2.approve(address(subscribe), fee2);

        vm.prank(user);
        subscribe.subscribe(address(mockStableCoin), 1);
        vm.prank(user);
        subscribe.subscribe(address(mockStableCoin2), 1);

        assertEq(mockStableCoin.balanceOf(feeReceiver), fee1);
        assertEq(mockStableCoin2.balanceOf(feeReceiver), fee2);
    }
}
