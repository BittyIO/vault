// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    IIntentProvider,
    TwapNotFound,
    TwapCompleted,
    TwapIntervalNotElapsed,
    TwapInvalidParams
} from "../../src/interfaces/IIntentProvider.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockIntentProvider is IIntentProvider {
    struct TwapOrder {
        address sellToken;
        address buyToken;
        uint256 sliceAmount;
        uint256 remainingAmount;
        uint256 minBuyAmountPerSlice;
        uint32 interval;
        uint32 sliceDuration;
        uint32 lastExecutedAt;
        uint16 numSlices;
        uint16 executedSlices;
    }

    mapping(bytes32 => TwapOrder) public twapOrders;

    function initialize(address) external override {}

    function trade(bytes memory data) external override {
        (address sellToken, uint256 sellAmount,,,,) =
            abi.decode(data, (address, uint256, address, uint256, uint32, bool));
        if (sellToken != address(0)) {
            IERC20(sellToken).transferFrom(msg.sender, address(this), sellAmount);
        }
        emit Trade(data, msg.sender, address(this));
    }

    /**
     * @notice Execute one slice of a TWAP order.
     * @dev Two call shapes (mirrors CoWSwapProvider):
     *   Create (224 bytes): abi.encode(sellToken, totalSellAmount, buyToken,
     *       minBuyAmountPerSlice, interval, sliceDuration, numSlices)
     *   Continue (32 bytes): abi.encode(twapId)
     */
    function twapTrade(bytes memory data) external override {
        if (data.length == 32) {
            _continueTwap(abi.decode(data, (bytes32)));
        } else {
            _createTwap(data);
        }
        emit Trade(data, msg.sender, address(this));
    }

    function _createTwap(bytes memory data) internal {
        (
            address sellToken,
            uint256 totalSellAmount,
            address buyToken,
            uint256 minBuyAmountPerSlice,
            uint32 interval,
            uint32 sliceDuration,
            uint16 numSlices
        ) = abi.decode(data, (address, uint256, address, uint256, uint32, uint32, uint16));

        if (numSlices < 2 || totalSellAmount == 0 || interval == 0 || sliceDuration == 0) {
            revert TwapInvalidParams();
        }

        IERC20(sellToken).transferFrom(msg.sender, address(this), totalSellAmount);

        uint256 sliceAmount = totalSellAmount / numSlices;
        bytes32 twapId = keccak256(
            abi.encode(msg.sender, sellToken, buyToken, totalSellAmount, numSlices, interval, block.timestamp)
        );

        twapOrders[twapId] = TwapOrder({
            sellToken: sellToken,
            buyToken: buyToken,
            sliceAmount: sliceAmount,
            remainingAmount: totalSellAmount - sliceAmount,
            minBuyAmountPerSlice: minBuyAmountPerSlice,
            interval: interval,
            sliceDuration: sliceDuration,
            lastExecutedAt: uint32(block.timestamp),
            numSlices: numSlices,
            executedSlices: 1
        });
    }

    function _continueTwap(bytes32 twapId) internal {
        TwapOrder storage order = twapOrders[twapId];
        if (order.numSlices == 0) revert TwapNotFound();
        if (order.executedSlices >= order.numSlices) revert TwapCompleted();
        if (block.timestamp < order.lastExecutedAt + order.interval) revert TwapIntervalNotElapsed();

        uint16 nextSlice = order.executedSlices + 1;
        bool isLastSlice = nextSlice == order.numSlices;
        uint256 thisSliceAmount = isLastSlice ? order.remainingAmount : order.sliceAmount;

        order.remainingAmount -= thisSliceAmount;
        order.lastExecutedAt = uint32(block.timestamp);
        order.executedSlices = nextSlice;
    }

    function cancelTwap(bytes32 twapId) external {
        TwapOrder storage order = twapOrders[twapId];
        if (order.numSlices == 0) revert TwapNotFound();

        address sellToken = order.sellToken;
        uint256 remaining = order.remainingAmount;
        delete twapOrders[twapId];

        if (remaining > 0) IERC20(sellToken).transfer(msg.sender, remaining);
    }

    function isValidSignature(bytes32, bytes memory) external pure override returns (bytes4) {
        return 0x1626ba7e;
    }

    function cancelTrade(bytes memory data) external override {
        emit CancelTrade(data, msg.sender, address(this));
    }

    function revokeApprovals(address[] calldata) external override {}

    function cleanExpiredOrders(bytes32[] calldata) external override {}
}
