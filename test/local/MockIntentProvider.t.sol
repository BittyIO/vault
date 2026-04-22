// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {MockIntentProvider} from "../mock/MockIntentProvider.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {
    TwapNotFound,
    TwapCompleted,
    TwapIntervalNotElapsed,
    TwapInvalidParams
} from "../../src/interfaces/IIntentProvider.sol";

contract MockIntentProviderTest is Test {
    MockIntentProvider provider;
    MockERC20 usdc;
    MockERC20 dai;

    address owner = makeAddr("owner");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        dai = new MockERC20("DAI", "DAI", 18);
        provider = new MockIntentProvider();
    }

    function _createData(
        uint256 totalSellAmount,
        uint256 minBuyAmountPerSlice,
        uint32 interval,
        uint32 sliceDuration,
        uint16 numSlices
    ) internal view returns (bytes memory) {
        return abi.encode(
            address(usdc), totalSellAmount, address(dai), minBuyAmountPerSlice, interval, sliceDuration, numSlices
        );
    }

    function _twapId(uint256 total, uint16 numSlices, uint32 interval, uint256 ts) internal view returns (bytes32) {
        return keccak256(abi.encode(owner, address(usdc), address(dai), total, numSlices, interval, ts));
    }

    function _create(uint256 total, uint16 numSlices, uint32 interval) internal returns (bytes32 twapId) {
        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, interval, 1800, numSlices));
        vm.stopPrank();
        twapId = _twapId(total, numSlices, interval, block.timestamp);
    }

    function test_twapTrade_CreatesNewTwap() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        uint32 interval = 3600;
        uint256 ts = block.timestamp;

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, interval, 1800, numSlices));
        vm.stopPrank();

        bytes32 id = _twapId(total, numSlices, interval, ts);
        (
            address sellToken,
            address buyToken,
            uint256 sliceAmount,
            uint256 remainingAmount,,
            uint32 storedInterval,,
            uint32 lastExec,
            uint16 storedNumSlices,
            uint16 executedSlices
        ) = provider.twapOrders(id);

        assertEq(sellToken, address(usdc));
        assertEq(buyToken, address(dai));
        assertEq(sliceAmount, total / numSlices);
        assertEq(remainingAmount, total - total / numSlices);
        assertEq(storedInterval, interval);
        assertEq(storedNumSlices, numSlices);
        assertEq(executedSlices, 1);
        assertEq(lastExec, uint32(ts));
    }

    function test_twapTrade_TransfersTokensToProvider() public {
        uint256 total = 1000e6;
        bytes32 id = _create(total, 4, 3600);

        assertEq(usdc.balanceOf(address(provider)), total);
        assertEq(usdc.balanceOf(owner), 0);
        (,,, uint256 remainingAmount,,,,,, uint16 executedSlices) = provider.twapOrders(id);
        assertEq(executedSlices, 1);
        assertEq(remainingAmount, total - total / 4);
    }

    function test_twapTrade_ExecutesNextSlice() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        uint32 interval = 3600;
        bytes32 id = _create(total, numSlices, interval);
        uint256 sliceAmount = total / numSlices;

        vm.warp(block.timestamp + interval);
        vm.prank(owner);
        provider.twapTrade(abi.encode(id));

        (,,, uint256 remainingAmount,,,,,, uint16 executedSlices) = provider.twapOrders(id);
        assertEq(executedSlices, 2);
        assertEq(remainingAmount, total - 2 * sliceAmount);
    }

    function test_twapTrade_LastSliceGetsRemainder() public {
        uint256 total = 1000e6 + 1;
        uint16 numSlices = 4;
        uint32 interval = 3600;
        bytes32 id = _create(total, numSlices, interval);
        uint256 sliceAmount = total / numSlices;
        uint256 expectedRemainder = total - sliceAmount * (numSlices - 1);

        for (uint256 i = 0; i < numSlices - 1; i++) {
            vm.warp(block.timestamp + interval);
            vm.prank(owner);
            provider.twapTrade(abi.encode(id));
        }

        (,,, uint256 remainingAfter,,,,,, uint16 executedSlices) = provider.twapOrders(id);
        assertEq(executedSlices, numSlices);
        assertEq(remainingAfter, 0);
        assertEq(sliceAmount * (numSlices - 1) + expectedRemainder, total);
    }

    function test_twapTrade_RevertsIfIntervalNotElapsed() public {
        bytes32 id = _create(1000e6, 4, 3600);

        vm.prank(owner);
        vm.expectRevert(TwapIntervalNotElapsed.selector);
        provider.twapTrade(abi.encode(id));
    }

    function test_twapTrade_RevertsIfCompleted() public {
        uint256 total = 600e6;
        uint16 numSlices = 2;
        uint32 interval = 3600;
        bytes32 id = _create(total, numSlices, interval);

        vm.warp(block.timestamp + interval);
        vm.prank(owner);
        provider.twapTrade(abi.encode(id));

        vm.warp(block.timestamp + interval);
        vm.prank(owner);
        vm.expectRevert(TwapCompleted.selector);
        provider.twapTrade(abi.encode(id));
    }

    function test_twapTrade_RevertsIfTwapNotFound() public {
        vm.expectRevert(TwapNotFound.selector);
        provider.twapTrade(abi.encode(keccak256("nonexistent")));
    }

    function test_twapTrade_RevertsInvalidParams() public {
        usdc.mint(owner, 1000e6);
        vm.startPrank(owner);
        usdc.approve(address(provider), 1000e6);

        vm.expectRevert(TwapInvalidParams.selector);
        provider.twapTrade(_createData(1000e6, 0, 3600, 1800, 1));
        vm.stopPrank();
    }

    function test_cancelTwap_ReturnsRemainingTokens() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        bytes32 id = _create(total, numSlices, 3600);

        uint256 sliceAmount = total / numSlices;
        uint256 expectedRemaining = total - sliceAmount;

        vm.prank(owner);
        provider.cancelTwap(id);

        assertEq(usdc.balanceOf(owner), expectedRemaining);
        assertEq(usdc.balanceOf(address(provider)), sliceAmount);
    }

    function test_cancelTwap_DeletesTwapRecord() public {
        bytes32 id = _create(1000e6, 4, 3600);

        vm.prank(owner);
        provider.cancelTwap(id);

        vm.expectRevert(TwapNotFound.selector);
        provider.cancelTwap(id);
    }
}
