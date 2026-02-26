// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ISwapProvider} from "../interfaces/ISwapProvider.sol";
import {IUniswapV4Router04, BaseData, PathKey} from "../libs/uniswap/v4/Uniswap.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

contract UniswapV4Provider is ISwapProvider, Ownable, Initializable {
    using SafeERC20 for IERC20;
    address public immutable router;
    address public immutable poolManager;

    constructor(address router_, address poolManager_) {
        router = router_;
        poolManager = poolManager_;
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    receive() external payable {}

    function swap(bytes memory data) external payable override onlyOwner {
        (address payAsset, uint256 amountIn,, uint256 amountOutMinimum, PathKey[] memory path) =
            abi.decode(data, (address, uint256, address, uint256, PathKey[]));

        address receiveAsset = path[path.length - 1].intermediateCurrency;

        BaseData memory baseData = BaseData({
            amount: amountIn, amountLimit: amountOutMinimum, payer: address(this), receiver: address(this), flags: 0
        });

        bytes memory routerData = abi.encode(baseData, payAsset, path);

        if (payAsset != address(0)) {
            IERC20(payAsset).safeTransferFrom(msg.sender, address(this), amountIn);
            IERC20(payAsset).safeApprove(router, amountIn);
        }

        IUniswapV4Router04(router).swap{value: msg.value}(routerData, block.timestamp);

        if (payAsset != address(0)) {
            IERC20(payAsset).safeApprove(router, 0);
        }

        if (address(this).balance != 0) {
            Address.sendValue(payable(msg.sender), address(this).balance);
        }
        if (receiveAsset != address(0)) {
            IERC20(receiveAsset).safeTransfer(msg.sender, IERC20(receiveAsset).balanceOf(address(this)));
        }
    }
}
