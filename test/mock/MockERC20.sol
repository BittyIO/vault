// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) {}
}
