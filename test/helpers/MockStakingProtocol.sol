// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1StakingProtocol} from "protocol-contracts/src/interfaces/IBittyV1StakingProtocol.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/// @dev Minimal cloneable staking mock used by the local vault tests. It holds the staked
/// asset 1:1 and records the recipient of the last on-behalf unstake so tests can assert
/// funds are delivered only to the configured scheduledPayment.
contract MockStakingProtocol is IBittyV1StakingProtocol, Ownable, Initializable {
    using SafeERC20 for IERC20;

    address public lastUnstakeRecipient;
    uint256 public lastUnstakeAmount;

    constructor() Ownable(msg.sender) {}

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    function stake(address asset, uint256 amount) external payable override onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    function getStakedBalance(address asset) external view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function unstake(address asset, uint256 amount, address recipient) external override onlyOwner returns (uint256) {
        return _unstake(asset, amount, recipient);
    }

    function _unstake(address asset, uint256 amount, address recipient) private returns (uint256) {
        if (amount == type(uint256).max) {
            amount = IERC20(asset).balanceOf(address(this));
        }
        lastUnstakeRecipient = recipient;
        lastUnstakeAmount = amount;
        IERC20(asset).safeTransfer(recipient, amount);
        return amount;
    }

    function getUnstakeRequestIds() external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    function claimUnstaked(uint256[] memory) external override onlyOwner {}

    /// @dev No separate receipt token — tells the vault's approval helper there is nothing to approve.
    function receiptTokenOf(address) external pure returns (address) {
        return address(0);
    }
}
