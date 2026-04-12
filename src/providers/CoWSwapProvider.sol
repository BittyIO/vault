// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    IIntentProvider,
    ApprovalNotFound,
    OrderNotExpired,
    TwapNotFound,
    TwapCompleted,
    TwapIntervalNotElapsed,
    TwapInvalidParams
} from "../interfaces/IIntentProvider.sol";
import {IGPv2Settlement} from "../libs/cow/GPv2Settlement.sol";
import {GPv2Order} from "../libs/cow/GPv2Order.sol";
import {IERC1271} from "../libs/cow/IERC1271.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/**
 * @title CoW Swap Provider
 * @notice IIntentProvider implementation for CoW Protocol using EIP-1271 and PreSign.
 * @dev Single orders use PreSign + EIP-1271 (`trade`).
 *      TWAP orders slice the total sell amount into N equal parts (`twapTrade`).
 *      Each part is a full GPv2 order: the provider approves the digest and sets a PreSignature,
 *      then an off-chain keeper calls twapTrade again after each interval elapses.
 *      Settlement of each slice is handled asynchronously by CoW solvers.
 */
contract CoWSwapProvider is IIntentProvider, IERC1271, Ownable, Initializable {
    using SafeERC20 for IERC20;

    // @dev EIP-1271 magic value for valid signature
    bytes4 private constant MAGICVALUE = 0x1626ba7e;

    // @dev Default order validity (1 hour) when not specified in swap data
    uint32 private constant DEFAULT_VALID_TO_OFFSET = 3600;

    IGPv2Settlement public immutable settlement;
    address public immutable vaultRelayer;

    // ─────────────── single-order state ───────────────

    // @dev Approved order digests for EIP-1271 signing (owner => digest => approved)
    mapping(address => mapping(bytes32 => bool)) public approvedOrderDigests;

    /// @dev Sell token used for a given order digest so cancelTrade can revoke vault relayer allowance
    mapping(bytes32 => address) private _digestToSellToken;

    /// @dev validTo for a given order digest, used by cleanExpiredOrders
    mapping(bytes32 => uint32) private _digestToValidTo;

    /// @dev Sell amount for a given order digest, used by cleanExpiredOrders to decrease allowance precisely
    mapping(bytes32 => uint256) private _digestToSellAmount;

    // ─────────────── TWAP state ───────────────

    /**
     * @dev On-chain state for an active TWAP schedule.
     *      Tokens are transferred in full on creation; vaultRelayer allowance is
     *      increased by `sliceAmount` (or the final remainder) on every slice.
     */
    struct TwapOrder {
        address sellToken;
        address buyToken;
        uint256 sliceAmount; // base amount per slice (totalSellAmount / numSlices)
        uint256 remainingAmount; // tokens not yet allocated to any slice
        uint256 minBuyAmountPerSlice; // minimum acceptable output per slice
        uint32 interval; // minimum seconds between slice executions
        uint32 sliceDuration; // validity window for each individual slice order
        uint32 lastExecutedAt; // timestamp when the most recent slice was initiated
        uint16 numSlices; // total number of slices
        uint16 executedSlices; // slices initiated so far (1-indexed after creation)
    }

    mapping(bytes32 => TwapOrder) public twapOrders;

    // ─────────────── events ───────────────

    /**
     * @notice Emitted when a new TWAP schedule is created (first slice included).
     */
    event TwapCreated(
        bytes32 indexed twapId,
        address sellToken,
        address buyToken,
        uint256 totalSellAmount,
        uint16 numSlices,
        uint32 interval
    );

    /**
     * @notice Emitted each time a TWAP slice is initiated.
     * @param sliceIndex 1-based index of the slice that was just initiated.
     * @param sliceDigest The GPv2 order digest approved for this slice.
     * @param validTo     The slice order expiry timestamp.
     */
    event TwapSliceInitiated(bytes32 indexed twapId, uint16 sliceIndex, bytes32 sliceDigest, uint32 validTo);

    /**
     * @param settlement_   GPv2Settlement contract address.
     * @param vaultRelayer_ CoW vault relayer address (approved for ERC-20 pulls during settlement).
     */
    constructor(address settlement_, address vaultRelayer_) {
        settlement = IGPv2Settlement(settlement_);
        vaultRelayer = vaultRelayer_;
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    receive() external payable {}

    /**
     * @notice Submit a single CoW Protocol order using PreSign + EIP-1271.
     * @dev Tokens are transferred to this contract and the vault relayer allowance is increased.
     *      The order must be submitted to the CoW API by an off-chain service.
     *      Settlement is asynchronous (solver fills the order in a batch).
     *
     * @param data Encoded: (sellToken, sellAmount, buyToken, buyAmountMin) or
     *             (sellToken, sellAmount, buyToken, buyAmountMin, validTo) or
     *             (sellToken, sellAmount, buyToken, buyAmountMin, validTo, isSellOrder)
     */
    function trade(bytes memory data) external override onlyOwner {
        (
            address sellToken,
            uint256 sellAmount,
            address buyToken,
            uint256 buyAmountMin,
            uint32 validTo,
            bool isSellOrder
        ) = _decodeSwapData(data);

        if (sellToken != address(0)) {
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmount);
            IERC20(sellToken).safeIncreaseAllowance(vaultRelayer, sellAmount);
        }

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(sellToken),
            buyToken: IERC20(buyToken),
            receiver: msg.sender,
            sellAmount: sellAmount,
            buyAmount: buyAmountMin,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: isSellOrder ? GPv2Order.KIND_SELL : GPv2Order.KIND_BUY,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes32 orderDigest = GPv2Order.hash(order, settlement.domainSeparator());
        bytes memory orderUid = GPv2Order.packOrderUid(orderDigest, address(this), validTo);

        approvedOrderDigests[owner()][orderDigest] = true;
        settlement.setPreSignature(orderUid, true);

        if (sellToken != address(0)) {
            _digestToSellToken[orderDigest] = sellToken;
            _digestToSellAmount[orderDigest] = sellAmount;
        }
        _digestToValidTo[orderDigest] = validTo;

        emit Trade(data, msg.sender, address(this));
    }

    /**
     * @notice Execute one slice of a TWAP order via CoW Protocol.
     * @dev Two call shapes:
     *   Create (224 bytes): abi.encode(sellToken, totalSellAmount, buyToken,
     *       minBuyAmountPerSlice, interval, sliceDuration, numSlices)
     *     – Transfers totalSellAmount from caller, initialises TWAP state, computes and
     *       approves the first slice's GPv2 order digest, increases vaultRelayer allowance
     *       by sliceAmount.  Returns the twapId via TwapCreated event.
     *   Continue (32 bytes): abi.encode(twapId)
     *     – Validates that the inter-slice interval has elapsed, computes and approves
     *       the next slice's GPv2 order digest, increases vaultRelayer allowance.
     *
     *   The off-chain keeper must:
     *   1. Call twapTrade with the Create shape to start the schedule.
     *   2. After each interval elapses, call twapTrade with the Continue shape.
     *   3. Submit each slice order to the CoW API; a solver will settle it.
     */
    function twapTrade(bytes memory data) external override onlyOwner {
        if (data.length == 32) {
            bytes32 twapId = abi.decode(data, (bytes32));
            _continueTwap(twapId);
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

        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), totalSellAmount);

        uint256 sliceAmount = totalSellAmount / numSlices;

        bytes32 twapId =
            keccak256(abi.encode(owner(), sellToken, buyToken, totalSellAmount, numSlices, interval, block.timestamp));

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

        (bytes32 sliceDigest, uint32 validTo) =
            _approveSlice(sellToken, buyToken, sliceAmount, minBuyAmountPerSlice, sliceDuration);

        emit TwapCreated(twapId, sellToken, buyToken, totalSellAmount, numSlices, interval);
        emit TwapSliceInitiated(twapId, 1, sliceDigest, validTo);
    }

    function _continueTwap(bytes32 twapId) internal {
        TwapOrder storage order = twapOrders[twapId];
        if (order.numSlices == 0) revert TwapNotFound();
        if (order.executedSlices >= order.numSlices) revert TwapCompleted();
        if (block.timestamp < order.lastExecutedAt + order.interval) revert TwapIntervalNotElapsed();

        uint16 nextSlice = order.executedSlices + 1;
        bool isLastSlice = nextSlice == order.numSlices;
        uint256 thisSliceAmount = isLastSlice ? order.remainingAmount : order.sliceAmount;

        (bytes32 sliceDigest, uint32 validTo) = _approveSlice(
            order.sellToken, order.buyToken, thisSliceAmount, order.minBuyAmountPerSlice, order.sliceDuration
        );

        order.remainingAmount -= thisSliceAmount;
        order.lastExecutedAt = uint32(block.timestamp);
        order.executedSlices = nextSlice;

        emit TwapSliceInitiated(twapId, nextSlice, sliceDigest, validTo);
    }

    /// @dev Builds a GPv2 sell order for one slice, approves its digest, sets PreSignature,
    ///      and increases vaultRelayer allowance.  Returns the digest and validTo.
    function _approveSlice(
        address sellToken,
        address buyToken,
        uint256 sliceAmount,
        uint256 minBuyAmount,
        uint32 sliceDuration
    ) internal returns (bytes32 sliceDigest, uint32 validTo) {
        validTo = uint32(block.timestamp + sliceDuration);

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(sellToken),
            buyToken: IERC20(buyToken),
            receiver: owner(),
            sellAmount: sliceAmount,
            buyAmount: minBuyAmount,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        sliceDigest = GPv2Order.hash(order, settlement.domainSeparator());
        bytes memory orderUid = GPv2Order.packOrderUid(sliceDigest, address(this), validTo);

        IERC20(sellToken).safeIncreaseAllowance(vaultRelayer, sliceAmount);
        approvedOrderDigests[owner()][sliceDigest] = true;
        settlement.setPreSignature(orderUid, true);

        _digestToSellToken[sliceDigest] = sellToken;
        _digestToSellAmount[sliceDigest] = sliceAmount;
        _digestToValidTo[sliceDigest] = validTo;
    }

    /**
     * @notice Cancel an active TWAP schedule and recover unallocated tokens.
     * @dev Only transfers back tokens not yet allocated to any slice (remainingAmount).
     *      The current active slice (if any) must be cancelled separately via cancelTrade,
     *      using the sliceDigest emitted in the most recent TwapSliceInitiated event.
     * @param twapId The TWAP schedule identifier from the TwapCreated event.
     */
    function cancelTwap(bytes32 twapId) external onlyOwner {
        TwapOrder storage order = twapOrders[twapId];
        if (order.numSlices == 0) revert TwapNotFound();

        address sellToken = order.sellToken;
        uint256 remaining = order.remainingAmount;
        delete twapOrders[twapId];

        if (remaining > 0) IERC20(sellToken).safeTransfer(msg.sender, remaining);
    }

    /**
     * @notice Approve an order digest for EIP-1271 signing (single orders).
     * @param orderDigest The EIP-712 order digest to approve.
     */
    function approveOrderDigest(bytes32 orderDigest) external onlyOwner {
        approvedOrderDigests[owner()][orderDigest] = true;
    }

    /**
     * @notice Revoke an approved order digest.
     * @param orderDigest The EIP-712 order digest to revoke.
     */
    function revokeOrderDigest(bytes32 orderDigest) external onlyOwner {
        approvedOrderDigests[owner()][orderDigest] = false;
    }

    /**
     * @notice Cancel a single trade by revoking its order digest and PreSignature.
     * @param data abi.encode(bytes32 orderDigest, uint32 validTo)
     */
    function cancelTrade(bytes memory data) external override onlyOwner {
        (bytes32 orderDigest, uint32 validTo) = abi.decode(data, (bytes32, uint32));
        approvedOrderDigests[owner()][orderDigest] = false;
        bytes memory orderUid = GPv2Order.packOrderUid(orderDigest, address(this), validTo);
        settlement.setPreSignature(orderUid, false);

        address sellToken = _digestToSellToken[orderDigest];
        if (sellToken != address(0)) {
            uint256 orderSellAmount = _digestToSellAmount[orderDigest];
            uint256 currentAllowance = IERC20(sellToken).allowance(address(this), vaultRelayer);
            uint256 decreaseBy = orderSellAmount < currentAllowance ? orderSellAmount : currentAllowance;
            if (decreaseBy > 0) IERC20(sellToken).safeDecreaseAllowance(vaultRelayer, decreaseBy);
            uint256 balance = IERC20(sellToken).balanceOf(address(this));
            uint256 toReturn = orderSellAmount < balance ? orderSellAmount : balance;
            if (toReturn > 0) IERC20(sellToken).safeTransfer(msg.sender, toReturn);
            delete _digestToSellToken[orderDigest];
            delete _digestToSellAmount[orderDigest];
        }
        delete _digestToValidTo[orderDigest];

        emit CancelTrade(data, msg.sender, address(this));
    }

    /**
     * @notice EIP-1271 signature verification for GPv2Settlement.
     */
    function isValidSignature(
        bytes32 hash,
        bytes memory /* signature */
    )
        external
        view
        override(IERC1271, IIntentProvider)
        returns (bytes4)
    {
        if (approvedOrderDigests[owner()][hash]) return MAGICVALUE;
        return 0xffffffff;
    }

    /**
     * @notice Compute order digest for a given order (for off-chain order submission).
     */
    function getOrderDigest(GPv2Order.Data memory order) external view returns (bytes32) {
        return GPv2Order.hash(order, settlement.domainSeparator());
    }

    function revokeApprovals(address[] calldata tokens) external override onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (IERC20(tokens[i]).allowance(address(this), vaultRelayer) == 0) continue;
            IERC20(tokens[i]).safeApprove(vaultRelayer, 0);
        }
    }

    function cleanExpiredOrders(bytes32[] calldata orderDigests) external override {
        for (uint256 i = 0; i < orderDigests.length; i++) {
            bytes32 orderDigest = orderDigests[i];
            if (_digestToValidTo[orderDigest] == 0 || block.timestamp <= _digestToValidTo[orderDigest]) {
                revert OrderNotExpired();
            }
            approvedOrderDigests[owner()][orderDigest] = false;
            bytes memory orderUid = GPv2Order.packOrderUid(orderDigest, address(this), _digestToValidTo[orderDigest]);
            settlement.setPreSignature(orderUid, false);
            address sellToken = _digestToSellToken[orderDigest];
            if (sellToken != address(0)) {
                uint256 orderSellAmount = _digestToSellAmount[orderDigest];
                uint256 currentAllowance = IERC20(sellToken).allowance(address(this), vaultRelayer);
                uint256 decreaseBy = orderSellAmount < currentAllowance ? orderSellAmount : currentAllowance;
                if (decreaseBy > 0) IERC20(sellToken).safeDecreaseAllowance(vaultRelayer, decreaseBy);
                uint256 balance = IERC20(sellToken).balanceOf(address(this));
                uint256 toReturn = orderSellAmount < balance ? orderSellAmount : balance;
                if (toReturn > 0) IERC20(sellToken).safeTransfer(owner(), toReturn);
                delete _digestToSellToken[orderDigest];
                delete _digestToSellAmount[orderDigest];
            }
            delete _digestToValidTo[orderDigest];
        }
    }

    function getOrderUid(GPv2Order.Data memory order) external view returns (bytes memory) {
        bytes32 digest = GPv2Order.hash(order, settlement.domainSeparator());
        return GPv2Order.packOrderUid(digest, address(this), order.validTo);
    }

    function _decodeSwapData(bytes memory data)
        internal
        view
        returns (
            address sellToken,
            uint256 sellAmount,
            address buyToken,
            uint256 buyAmountMin,
            uint32 validTo,
            bool isSellOrder
        )
    {
        if (data.length >= 192) {
            (sellToken, sellAmount, buyToken, buyAmountMin, validTo, isSellOrder) =
                abi.decode(data, (address, uint256, address, uint256, uint32, bool));
        } else if (data.length >= 160) {
            (sellToken, sellAmount, buyToken, buyAmountMin, validTo) =
                abi.decode(data, (address, uint256, address, uint256, uint32));
            isSellOrder = true;
        } else {
            (sellToken, sellAmount, buyToken, buyAmountMin) = abi.decode(data, (address, uint256, address, uint256));
            validTo = uint32(block.timestamp + DEFAULT_VALID_TO_OFFSET);
            isSellOrder = true;
        }
    }
}
