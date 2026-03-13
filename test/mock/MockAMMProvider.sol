// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IAMMProvider} from "../../src/interfaces/IAMMProvider.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockAMMProvider is IAMMProvider {
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
                payable(msg.sender).transfer(buyAmountMin);
            } else {
                IERC20(buyAssetAddress).transfer(msg.sender, buyAmountMin);
            }
        }
    }

    function addLiquidity(bytes memory) external payable override {}

    function removeLiquidity(bytes memory) external payable override {}

    function claimFees(bytes memory) external payable override {}

    function getLiquidity(bytes memory) external pure override returns (uint256) {
        return 0;
    }

    receive() external payable {}
}
