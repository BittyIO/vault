// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IStETH} from "../../src/libs/Lido.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockStETH is ERC20, IStETH {
    // 1:1 exchange rate for simplicity in tests
    uint256 private constant EXCHANGE_RATE = 1e18;

    constructor() ERC20("Mock stETH", "stETH") {}

    function submit(address /* _referral */) external payable override returns (uint256) {
        // Mint stETH 1:1 with ETH received
        uint256 shares = msg.value;
        _mint(msg.sender, shares);
        return shares;
    }

    function getSharesByPooledEth(uint256 _ethAmount) external pure override returns (uint256) {
        // 1:1 exchange rate
        return _ethAmount;
    }

    function getPooledEthByShares(uint256 _sharesAmount) external pure override returns (uint256) {
        // 1:1 exchange rate
        return _sharesAmount;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

