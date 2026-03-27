// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IStakingProvider, UnstakeMoreThanStaked} from "../interfaces/IStakingProvider.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IStETH, IUnstETH} from "../libs/lido/v2/Lido.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {WETHBalanceNotEnough} from "../interfaces/IVault.sol";
import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

contract LidoV2Provider is IStakingProvider, Ownable, Initializable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    EnumerableSet.UintSet private _unstakeRequests;
    IStETH public immutable stETH;
    IUnstETH public immutable unstETH;
    WETH public immutable weth;

    constructor(address stETH_, address unstETH_, address weth_) {
        stETH = IStETH(stETH_);
        unstETH = IUnstETH(unstETH_);
        weth = WETH(payable(weth_));
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    receive() external payable {}

    function stake(uint256 amount) external payable override onlyOwner {
        if (weth.balanceOf(msg.sender) < amount) {
            revert WETHBalanceNotEnough();
        }
        IERC20(address(weth)).safeTransferFrom(msg.sender, address(this), amount);
        weth.withdraw(amount);
        stETH.submit{value: amount}(address(this));
    }

    function getStakingBalance() external view override returns (uint256) {
        return stETH.balanceOf(address(this));
    }

    function getUnstakeRequestIds() external view override returns (uint256[] memory) {
        return _unstakeRequests.values();
    }

    function unstake(uint256 amount) external override onlyOwner {
        if (stETH.balanceOf(address(this)) < amount) {
            revert UnstakeMoreThanStaked();
        }
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        IERC20(address(stETH)).safeIncreaseAllowance(address(unstETH), amount);
        uint256[] memory requestIds = unstETH.requestWithdrawals(amounts, address(this));
        _unstakeRequests.add(requestIds[0]);
    }

    function claim(uint256[] memory requestIds) external override onlyOwner {
        uint256[] memory oneIds = new uint256[](1);
        uint256 ethBefore = address(this).balance;
        for (uint256 i = 0; i < requestIds.length; i++) {
            oneIds[0] = requestIds[i];
            IUnstETH.WithdrawalRequestStatus[] memory statuses = unstETH.getWithdrawalStatus(oneIds);
            if (statuses[0].isFinalized && !statuses[0].isClaimed) {
                unstETH.claimWithdrawal(requestIds[i]);
                _unstakeRequests.remove(requestIds[i]);
            }
        }
        uint256 ethClaimed = address(this).balance - ethBefore;
        if (ethClaimed > 0) {
            weth.deposit{value: ethClaimed}();
            IERC20(address(weth)).safeTransfer(msg.sender, ethClaimed);
        }
    }
}
