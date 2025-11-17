// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {MockERC20} from "./MockERC20.sol";

contract MockWETH is MockERC20 {
    constructor() MockERC20("WETH", "WETH", 18) {}

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        payable(msg.sender).transfer(amount);
    }
}
