// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TRC20Transfer
 * @notice {SafeERC20-safeTransfer} for TRON, where the chain's main stablecoin breaks it.
 * @dev USDT on TRON (TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t) declares `transfer` as `returns (bool)` but
 *      never returns, so a SUCCESSFUL transfer reads as `false` and OpenZeppelin's safeTransfer
 *      reverts — every send, fee and adapter payout in USDT would fail. (Its `transferFrom` and
 *      `approve` do return true, so those keep using SafeERC20.)
 *
 *      Same rules as safeTransfer, with one addition: a `false` return is accepted when the sender's
 *      balance fell by exactly `value`. The sender side, not the recipient's, so the check still holds
 *      if USDT ever turns on its transfer fee (taken out of `value`, not on top of it). A token that
 *      returns false and moves nothing still reverts, as it would under SafeERC20.
 */
library TRC20Transfer {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        uint256 before = token.balanceOf(address(this));
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, value)));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        if (ret.length == 0) {
            if (address(token).code.length == 0) revert SafeERC20.SafeERC20FailedOperation(address(token));
            return;
        }
        if (abi.decode(ret, (bool))) return;
        uint256 afterwards = token.balanceOf(address(this));
        if (afterwards > before || before - afterwards != value) {
            revert SafeERC20.SafeERC20FailedOperation(address(token));
        }
    }
}
