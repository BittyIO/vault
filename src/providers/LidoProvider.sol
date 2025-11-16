// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IYieldProvider} from "../interfaces/IAssetManager.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IStETH, IUnstETH} from "../libs/Lido.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";

contract LidoProvider is IYieldProvider, Ownable, Initializable {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using EnumerableSet for EnumerableSet.UintSet;
    EnumerableSet.UintSet private _withdrawalRequests;
    IStETH public immutable stETH;
    IUnstETH public immutable unstETH;
    IWETH public immutable weth;

    error InvalidAsset();

    constructor(address stETH_, address unstETH_, address weth_) {
        stETH = IStETH(stETH_);
        unstETH = IUnstETH(unstETH_);
        weth = IWETH(weth_);
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    function supply(address asset, uint256 amount) external payable override onlyOwner {
        if (asset != address(0) && amount != msg.value) {
            revert InvalidAsset();
        }
        stETH.submit{value: amount}(address(this));
    }

    function withdraw(address asset, uint256 amount) external override onlyOwner {
        if (asset != address(0)) {
            revert InvalidAsset();
        }
        if (amount == 0) {
            for (uint256 i = 0; i < _withdrawalRequests.length(); i++) {
                uint256 requestId = _withdrawalRequests.at(i);
                uint256[] memory requestIds = new uint256[](1);
                requestIds[0] = requestId;
                IUnstETH.WithdrawalRequestStatus[] memory statuses = unstETH.getWithdrawalStatus(requestIds);
                if (statuses[0].isFinalized && !statuses[0].isClaimed) {
                    unstETH.claimWithdrawal(requestId);
                    _withdrawalRequests.remove(requestId);
                    if (address(this).balance > 0) {
                        Address.sendValue(payable(msg.sender), address(this).balance);
                    }
                }
            }
        } else {
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = amount;
            // Approve unstETH to transfer stETH
            IERC20(address(stETH)).safeIncreaseAllowance(address(unstETH), amount);
            uint256[] memory requestIds = unstETH.requestWithdrawals(amounts, address(this));
            _withdrawalRequests.add(requestIds[0]);
        }
    }

    function getBalance(address asset) external view override returns (uint256) {
        if (asset != address(0)) {
            revert InvalidAsset();
        }
        return stETH.balanceOf(address(this));
    }
}
