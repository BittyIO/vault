// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1AMMProtocol} from "protocol-contracts/src/interfaces/IBittyV1AMMProtocol.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

contract MockAMMProtocol is IBittyV1AMMProtocol {
    using SafeERC20 for IERC20;

    uint256 public decreaseLiquidityCallCount;
    uint256 public removeLiquidityCallCount;
    bytes public lastDecreaseData;
    bytes public lastRemoveData;

    address public lastSwapRecipient;
    uint256 public lastSwapBuyAmount;

    function initialize(address) external override {}

    function swap(bytes memory data, address recipient) external payable override {
        (address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmountMin) =
            abi.decode(data, (address, uint256, address, uint256));
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmount);
        lastSwapRecipient = recipient;
        lastSwapBuyAmount = buyAmountMin;
        MockERC20(buyToken).mint(recipient, buyAmountMin);
    }

    /**
     * @dev Simulated exact-output swap: pulls the sell token from the caller (the vault) and mints the
     * exact bought amount to `recipient`, so the recipient-side delivery can be asserted.
     */
    function swapExactOut(bytes memory data, address recipient) external override {
        (address sellToken, uint256 sellAmountMax, address buyToken, uint256 buyAmount) =
            abi.decode(data, (address, uint256, address, uint256));
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmountMax);
        lastSwapRecipient = recipient;
        lastSwapBuyAmount = buyAmount;
        MockERC20(buyToken).mint(recipient, buyAmount);
    }

    function addLiquidity(bytes memory) external override {}

    function removeLiquidity(bytes memory data) external override {
        removeLiquidityCallCount++;
        lastRemoveData = data;
    }

    function decreaseLiquidity(bytes memory data) external override {
        decreaseLiquidityCallCount++;
        lastDecreaseData = data;
    }

    function claimAMMFees(bytes memory) external override {}

    function getLiquidity(bytes memory) external pure override returns (uint256) {
        return 0;
    }
}
