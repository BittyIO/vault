// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

// Records invalidateOrder calls so a cancel test can assert the vault forwarded each order UID to the
// intent protocol's settlement contract (GPv2Settlement in production).
contract MockSettlement {
    bytes[] public invalidated;

    function invalidateOrder(bytes calldata orderUid) external {
        invalidated.push(orderUid);
    }

    function invalidatedCount() external view returns (uint256) {
        return invalidated.length;
    }
}
