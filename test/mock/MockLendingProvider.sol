// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ILendingProvider} from "../../src/interfaces/ILendingProvider.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockLendingProvider is ILendingProvider {
    mapping(address => uint256) public balances;
    mapping(address => IERC20) public tokens;

    function initialize(address newOwner) external override {}

    function supply(address asset, uint256 amount) external payable override {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        balances[asset] += amount;
    }

    function withdraw(address asset, uint256 amount) external override {
        require(balances[asset] >= amount, "Insufficient balance");
        balances[asset] -= amount;
        IERC20(asset).transfer(msg.sender, amount);
    }

    function getLendingBalance(address asset) external view override returns (uint256) {
        return balances[asset];
    }
}
