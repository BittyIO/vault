// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {IBittyV1Yield} from "protocol-contracts/src/interfaces/IBittyV1Yield.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/**
 * @dev Minimal cloneable staking mock used by the local vault tests. It holds the staked
 * asset 1:1 and records the recipient of the last on-behalf unstake so tests can assert
 * funds are delivered only to the configured scheduledPayment.
 */
contract MockStakingProtocol is IBittyV1Protocol, IBittyV1Yield, Ownable, Initializable {
    function protocolLineage() external pure returns (bytes32) {
        return keccak256("bitty.mock.staking");
    }

    function protocolVersion() external pure returns (uint256) {
        return 1_000_000;
    }

    function versionName() external pure returns (string memory) {
        return "1.0.0";
    }

    using SafeERC20 for IERC20;

    address public lastUnstakeRecipient;
    uint256 public lastUnstakeAmount;

    constructor() Ownable(msg.sender) {}

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    function deposit(address asset, uint256 amount) external override onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    function getBalance(address asset) external view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function withdraw(address asset, uint256 amount, address recipient) external override onlyOwner returns (uint256) {
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

    function getPendingWithdrawalIds() external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    function claimWithdrawals(uint256[] memory) external override onlyOwner {}

    /**
     * @dev No separate receipt token — tells the vault's approval helper there is nothing to approve.
     */
    function receiptTokenOf(address) external pure returns (address) {
        return address(0);
    }

    /**
     * @dev Answers the id the guard used to probe for, purely so {detectCategory} files this mock
     *      under the staking category. Nothing in the vault reads that category any more - it is a
     *      label for whoever reads the guard - and the mock is otherwise a plain depositable.
     *      `virtual` so subclasses can differ.
     */
    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        return interfaceId == 0xc8ada217 || interfaceId == 0x01ffc9a7;
    }
}
