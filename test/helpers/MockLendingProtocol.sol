// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1LendingProtocol} from "protocol-contracts/src/interfaces/IBittyV1LendingProtocol.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/// @dev Minimal cloneable lending mock used by the local vault tests. It holds the supplied
/// asset 1:1 and records the recipient of the last on-behalf withdraw so tests can assert
/// funds are delivered only to the configured receiver.
contract MockLendingProtocol is IBittyV1LendingProtocol, Ownable, Initializable {
    using SafeERC20 for IERC20;

    address public lastWithdrawRecipient;
    uint256 public lastWithdrawAmount;

    constructor() Ownable(msg.sender) {}

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    function supply(address asset, uint256 amount) external payable override onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    function getSuppliedBalance(address asset) external view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function withdraw(address asset, uint256 amount) external override onlyOwner {
        _withdraw(asset, amount, msg.sender);
    }

    function withdrawTo(address asset, uint256 amount, address recipient)
        external
        override
        onlyOwner
        returns (uint256)
    {
        return _withdraw(asset, amount, recipient);
    }

    function _withdraw(address asset, uint256 amount, address recipient) private returns (uint256) {
        if (amount == type(uint256).max) {
            amount = IERC20(asset).balanceOf(address(this));
        }
        lastWithdrawRecipient = recipient;
        lastWithdrawAmount = amount;
        IERC20(asset).safeTransfer(recipient, amount);
        return amount;
    }

    /// @dev No separate receipt token — tells the vault's approval helper there is nothing to approve.
    function receiptTokenOf(address) external pure returns (address) {
        return address(0);
    }
}
