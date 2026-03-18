// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title CoW Protocol GPv2 Order Library
/// @notice Minimal interface for CoW Protocol order hashing (EIP-712)
library GPv2Order {
    /// @dev The complete data for a CoW Protocol order
    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        bytes32 kind;
        bool partiallyFillable;
        bytes32 sellTokenBalance;
        bytes32 buyTokenBalance;
    }

    /// @dev EIP-712 type hash for the Order struct
    bytes32 internal constant TYPE_HASH = hex"d5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489";

    /// @dev Marker for sell orders
    bytes32 internal constant KIND_SELL = hex"f3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775";

    /// @dev Marker for buy orders
    bytes32 internal constant KIND_BUY = hex"6ed88e868af0a1983e3886d5f3e95a2fafbd6c3450bc229e27342283dc429ccc";

    /// @dev Use direct ERC20 balances
    bytes32 internal constant BALANCE_ERC20 = hex"5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9";

    /// @dev Order UID length
    uint256 internal constant UID_LENGTH = 56;

    /// @dev Compute EIP-712 order digest
    function hash(Data memory order, bytes32 domainSeparator) internal pure returns (bytes32 orderDigest) {
        bytes32 structHash = keccak256(
            abi.encode(
                TYPE_HASH,
                order.sellToken,
                order.buyToken,
                order.receiver,
                order.sellAmount,
                order.buyAmount,
                order.validTo,
                order.appData,
                order.feeAmount,
                order.kind,
                order.partiallyFillable,
                order.sellTokenBalance,
                order.buyTokenBalance
            )
        );
        orderDigest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /// @dev Pack order UID from digest, owner, and validTo
    /// @dev Layout: orderDigest (32) || owner (20) || validTo (4) = 56 bytes
    function packOrderUid(bytes32 orderDigest, address owner, uint32 validTo)
        internal
        pure
        returns (bytes memory orderUid)
    {
        orderUid = new bytes(UID_LENGTH);
        assembly {
            mstore(add(orderUid, 56), validTo)
            mstore(add(orderUid, 52), owner)
            mstore(add(orderUid, 32), orderDigest)
        }
    }
}
