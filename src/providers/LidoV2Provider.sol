// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IStakingProvider, UnstakeMoreThanStaked} from "../interfaces/IStakingProvider.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IStETH, IUnstETH} from "../libs/Lido.sol";
import {ETHBalanceNotEnough} from "../interfaces/IVault.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

contract LidoV2Provider is IStakingProvider, Ownable, Initializable {
    using SafeERC20 for IERC20;
    using SafeERC20 for WETH;
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

    function stake(uint256 amount) external payable override onlyOwner {
        if (address(this).balance < amount) {
            revert ETHBalanceNotEnough();
        }
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

    function claim() external override onlyOwner {
        for (uint256 i = 0; i < _unstakeRequests.length(); i++) {
            uint256 requestId = _unstakeRequests.at(i);
            uint256[] memory requestIds = new uint256[](1);
            requestIds[0] = requestId;
            IUnstETH.WithdrawalRequestStatus[] memory statuses = unstETH.getWithdrawalStatus(requestIds);
            if (statuses[0].isFinalized && !statuses[0].isClaimed) {
                unstETH.claimWithdrawal(requestId);
                _unstakeRequests.remove(requestId);
            }
        }
    }
}
