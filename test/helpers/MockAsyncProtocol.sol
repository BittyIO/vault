// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {IBittyV1Yield, WithdrawToNotSupported} from "protocol-contracts/src/interfaces/IBittyV1Yield.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/**
 * @dev Lido-shaped asynchronous mock for the local vault tests: `withdraw` consumes the position into
 * a queue and returns 0 — nothing is delivered in the same call — and, like the real adapter, it only
 * accepts the vault itself as the recipient. Exists so tests can prove a payout shortfall cannot be
 * funded from (and therefore cannot force an exit of) an asynchronous position.
 */
contract MockAsyncProtocol is IBittyV1Protocol, IBittyV1Yield, Ownable, Initializable {
    using SafeERC20 for IERC20;

    uint256 public queued;

    constructor() Ownable(msg.sender) {}

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    function protocolLineage() external pure returns (bytes32) {
        return keccak256("bitty.mock.async");
    }

    function protocolVersion() external pure returns (uint256) {
        return 1_000_000;
    }

    function versionName() external pure returns (string memory) {
        return "1.0.0";
    }

    function deposit(address asset, uint256 amount) external override onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    function getBalance(address asset) external view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) - queued;
    }

    function withdraw(address, uint256 amount, address recipient) external override onlyOwner returns (uint256) {
        if (recipient != owner()) revert WithdrawToNotSupported();
        queued += amount;
        return 0;
    }

    function getPendingWithdrawalIds() external view override returns (uint256[] memory ids) {
        if (queued > 0) {
            ids = new uint256[](1);
            ids[0] = 1;
        }
    }

    function claimWithdrawals(uint256[] memory) external override onlyOwner {
        queued = 0;
    }
}
