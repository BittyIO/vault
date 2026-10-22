// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";

contract MockIntentProtocol is IBittyV1IntentProtocol {
    function protocolLineage() external pure returns (bytes32) {
        return keccak256("bitty.mock.intent");
    }

    function protocolVersion() external pure returns (uint256) {
        return 1_000_000;
    }

    function versionName() external pure returns (string memory) {
        return "1.0.0";
    }

    // Immutable, so the vault's clone (a proxy onto this) answers with it too.
    address public immutable spender;

    address public owner;
    bytes[] public cancelled;

    constructor(address spender_) {
        spender = spender_;
    }

    function initialize(address newOwner) external override {
        owner = newOwner;
    }

    function isValidSignature(bytes32, bytes memory) external pure override returns (bytes4) {
        return 0x1626ba7e;
    }

    function cancelOrders(bytes[] calldata orderIds) external override {
        require(msg.sender == owner, "only the vault");
        for (uint256 i; i < orderIds.length; ++i) {
            cancelled.push(orderIds[i]);
        }
        emit OrdersCancelled(orderIds);
    }

    function isOrderCancelled(bytes calldata orderId) external view override returns (bool) {
        for (uint256 i; i < cancelled.length; ++i) {
            if (keccak256(cancelled[i]) == keccak256(orderId)) return true;
        }
        return false;
    }

    function cancelledCount() external view returns (uint256) {
        return cancelled.length;
    }

    /**
     * @dev Declares its category so the guard will register it; `virtual` so subclasses can differ.
     */
    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        return interfaceId == type(IBittyV1IntentProtocol).interfaceId || interfaceId == 0x01ffc9a7;
    }
}
