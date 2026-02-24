// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ISwapProvider} from "../interfaces/ISwapProvider.sol";
import {IUniswapV3Router} from "../libs/uniswap/v3/Uniswap.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

contract UniswapV3Provider is ISwapProvider, Ownable, Initializable {
    using SafeERC20 for IERC20;

    address public immutable router;

    constructor(address router_) {
        router = router_;
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    receive() external payable {}

    function swap(bytes memory data) external payable override onlyOwner {
        (address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOutMinimum, bytes memory path) =
            abi.decode(data, (address, uint256, address, uint256, bytes));

        IUniswapV3Router.ExactInputParams memory params = IUniswapV3Router.ExactInputParams({
            path: path, recipient: address(this), amountIn: amountIn, amountOutMinimum: amountOutMinimum
        });

        if (tokenIn != address(0)) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            IERC20(tokenIn).safeApprove(router, amountIn);
        }

        uint256 amountOut = IUniswapV3Router(router).exactInput{value: msg.value}(params);

        if (tokenIn != address(0)) {
            IERC20(tokenIn).safeApprove(router, 0);
        }

        if (address(this).balance != 0) {
            Address.sendValue(payable(msg.sender), address(this).balance);
        }

        if (tokenOut != address(0)) {
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        }
    }
}
