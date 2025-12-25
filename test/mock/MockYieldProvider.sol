// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IYieldProvider} from "../../src/interfaces/IAssetManager.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockYieldProvider is IYieldProvider {
    mapping(address => uint256) public balances;

    function initialize(address newOwner) external override {}

    function supply(address asset, uint256 amount) external payable override {
        if (asset == address(0)) {
            // Handle ETH
            require(msg.value == amount, "ETH amount mismatch");
            balances[asset] += amount;
        } else {
            // Handle ERC20
            IERC20(asset).transferFrom(msg.sender, address(this), amount);
            balances[asset] += amount;
        }
    }

    function withdraw(address asset, uint256 amount) external override {
        require(balances[asset] >= amount, "Insufficient balance");
        balances[asset] -= amount;
        if (asset == address(0)) {
            // Handle ETH
            payable(msg.sender).transfer(amount);
        } else {
            // Handle ERC20
            IERC20(asset).transfer(msg.sender, amount);
        }
    }

    function getBalance(address asset) external view override returns (uint256) {
        return balances[asset];
    }

    receive() external payable {}
}
