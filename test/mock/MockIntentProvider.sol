// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IIntentProvider} from "../../src/interfaces/IIntentProvider.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockIntentProvider is IIntentProvider {
    function initialize(address) external override {}

    function trade(bytes memory data) external payable override {
        (address sellToken, uint256 sellAmount,,,,) =
            abi.decode(data, (address, uint256, address, uint256, uint32, bool));
        if (sellToken != address(0)) {
            IERC20(sellToken).transferFrom(msg.sender, address(this), sellAmount);
        }
        emit Trade(data, msg.sender, address(this));
    }

    function isValidSignature(bytes32, bytes memory) external pure override returns (bytes4) {
        return 0x1626ba7e;
    }

    function cancelTrade(bytes memory data) external override {
        emit CancelTrade(data, msg.sender, address(this));
    }
}
