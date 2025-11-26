// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ISwapProvider} from "../../src/interfaces/IAssetManager.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockSwapProvider is ISwapProvider {
    function initialize(address newOwner) external override {}

    function swap(bytes memory data) external payable {
        (address sellAssetAddress, uint256 sellAmount, address buyAssetAddress, uint256 buyAmountMin) =
            abi.decode(data, (address, uint256, address, uint256));
        if (sellAssetAddress == address(0)) {
            require(msg.value == sellAmount, "ETH amount mismatch");
        } else {
            IERC20(sellAssetAddress).transferFrom(msg.sender, address(this), sellAmount);
        }

        if (buyAssetAddress != address(0) && buyAmountMin > 0) {
            if (buyAssetAddress == address(0)) {
                // Returning ETH
                payable(msg.sender).transfer(buyAmountMin);
            } else {
                // Returning ERC20 token
                IERC20(buyAssetAddress).transfer(msg.sender, buyAmountMin);
            }
        }
    }

    receive() external payable {}
}
