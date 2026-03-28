// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IAMMProvider} from "../interfaces/IAMMProvider.sol";
import {IUniswapV3Router, INonfungiblePositionManager} from "../libs/uniswap/v3/Uniswap.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

contract UniswapV3Provider is IAMMProvider, Ownable, Initializable {
    using SafeERC20 for IERC20;

    address public immutable router;
    address public immutable positionManager;

    constructor(address router_, address positionManager_) {
        router = router_;
        positionManager = positionManager_;
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

    function addLiquidity(bytes memory data) external payable override onlyOwner {
        (bool isMint, bytes memory paramsEncoded) = abi.decode(data, (bool, bytes));
        if (isMint) {
            INonfungiblePositionManager.MintParams memory params =
                abi.decode(paramsEncoded, (INonfungiblePositionManager.MintParams));
            params.recipient = address(this);
            if (params.token0 != address(0)) {
                IERC20(params.token0).safeTransferFrom(msg.sender, address(this), params.amount0Desired);
                IERC20(params.token0).safeApprove(positionManager, params.amount0Desired);
            }
            if (params.token1 != address(0)) {
                IERC20(params.token1).safeTransferFrom(msg.sender, address(this), params.amount1Desired);
                IERC20(params.token1).safeApprove(positionManager, params.amount1Desired);
            }
            (,, uint256 amount0Used, uint256 amount1Used) = INonfungiblePositionManager(positionManager).mint(params);
            if (params.token0 != address(0)) {
                IERC20(params.token0).safeApprove(positionManager, 0);
                uint256 leftover0 = params.amount0Desired - amount0Used;
                if (leftover0 > 0) IERC20(params.token0).safeTransfer(msg.sender, leftover0);
            }
            if (params.token1 != address(0)) {
                IERC20(params.token1).safeApprove(positionManager, 0);
                uint256 leftover1 = params.amount1Desired - amount1Used;
                if (leftover1 > 0) IERC20(params.token1).safeTransfer(msg.sender, leftover1);
            }
        } else {
            INonfungiblePositionManager.IncreaseLiquidityParams memory params =
                abi.decode(paramsEncoded, (INonfungiblePositionManager.IncreaseLiquidityParams));
            (,, address token0, address token1,,,,,,,,) =
                INonfungiblePositionManager(positionManager).positions(params.tokenId);
            if (token0 != address(0)) {
                IERC20(token0).safeTransferFrom(msg.sender, address(this), params.amount0Desired);
                IERC20(token0).safeApprove(positionManager, params.amount0Desired);
            }
            if (token1 != address(0)) {
                IERC20(token1).safeTransferFrom(msg.sender, address(this), params.amount1Desired);
                IERC20(token1).safeApprove(positionManager, params.amount1Desired);
            }
            (, uint256 amount0Used, uint256 amount1Used) =
                INonfungiblePositionManager(positionManager).increaseLiquidity(params);
            if (token0 != address(0)) {
                IERC20(token0).safeApprove(positionManager, 0);
                uint256 leftover0 = params.amount0Desired - amount0Used;
                if (leftover0 > 0) IERC20(token0).safeTransfer(msg.sender, leftover0);
            }
            if (token1 != address(0)) {
                IERC20(token1).safeApprove(positionManager, 0);
                uint256 leftover1 = params.amount1Desired - amount1Used;
                if (leftover1 > 0) IERC20(token1).safeTransfer(msg.sender, leftover1);
            }
        }
    }

    function removeLiquidity(bytes memory data) external payable override onlyOwner {
        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            abi.decode(data, (INonfungiblePositionManager.DecreaseLiquidityParams));
        INonfungiblePositionManager(positionManager).decreaseLiquidity(params);
        INonfungiblePositionManager(positionManager)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: params.tokenId,
                    recipient: msg.sender,
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
    }

    function claimFees(bytes memory data) external payable override onlyOwner {
        INonfungiblePositionManager.CollectParams memory params =
            abi.decode(data, (INonfungiblePositionManager.CollectParams));
        if (params.recipient == address(0)) params.recipient = msg.sender;
        INonfungiblePositionManager(positionManager).collect(params);
    }

    function getLiquidity(bytes memory data) external view override returns (uint256) {
        uint256 tokenId = abi.decode(data, (uint256));
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(positionManager).positions(tokenId);
        return uint256(liquidity);
    }
}
