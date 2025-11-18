// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
