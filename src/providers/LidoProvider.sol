// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IYieldProvider} from "../interfaces/IAssetManager.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IStETH, IUnstETH} from "../libs/Lido.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";

contract LidoProvider is IYieldProvider, Ownable, Initializable {
    using SafeERC20 for IERC20;
    using SafeERC20 for WETH;
    using EnumerableSet for EnumerableSet.UintSet;
    EnumerableSet.UintSet private _withdrawalRequests;
    IStETH public immutable stETH;
    IUnstETH public immutable unstETH;
    WETH public immutable weth;

    error InvalidAsset();

    constructor(address stETH_, address unstETH_, address weth_) {
        stETH = IStETH(stETH_);
        unstETH = IUnstETH(unstETH_);
        weth = WETH(payable(weth_));
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
        uint256[] memory requestIds = _withdrawalRequests.values();
        IUnstETH.WithdrawalRequestStatus[] memory _statuses;
        uint256[] memory _requestIds = new uint256[](1);
        uint256 _requestId;

        for (uint256 i = 0; i < requestIds.length; i++) {
            _requestId = requestIds[i];
            _requestIds[0] = _requestId;
            _statuses = unstETH.getWithdrawalStatus(_requestIds);
            if (_statuses[0].isFinalized && !_statuses[0].isClaimed) {
                unstETH.claimWithdrawal(_requestId);
                _withdrawalRequests.remove(_requestId);
            }
        }

        if (amount > 0) {
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = amount;
            // Approve unstETH to transfer stETH
            IERC20(address(stETH)).safeIncreaseAllowance(address(unstETH), amount);
            _withdrawalRequests.add(unstETH.requestWithdrawals(amounts, address(this))[0]);
        }

        if (address(this).balance > 0) {
            Address.sendValue(payable(msg.sender), address(this).balance);
        }
    }

    function getWithdrawalStatus() external view returns (IUnstETH.WithdrawalRequestStatus[] memory statuses) {
        uint256[] memory requestIds = _withdrawalRequests.values();
        return unstETH.getWithdrawalStatus(requestIds);
    }

    function getBalance(address asset) external view override returns (uint256) {
        if (asset != address(0)) {
            revert InvalidAsset();
        }
        return stETH.balanceOf(address(this));
    }

    receive() external payable {}
}
