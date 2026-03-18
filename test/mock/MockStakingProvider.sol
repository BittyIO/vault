// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IStakingProvider} from "../../src/interfaces/IStakingProvider.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

contract MockStakingProvider is IStakingProvider {
    using EnumerableSet for EnumerableSet.UintSet;

    mapping(address => uint256) public balances;
    address public weth;

    EnumerableSet.UintSet private _unstakeRequests;
    mapping(uint256 => uint256) private _requestAmounts;
    uint256 private _nextRequestId;

    function initialize(address newOwner) external override {}

    function setWethAddress(address wethAddress) external {
        weth = wethAddress;
    }

    function stake(uint256 amount) external payable override {
        IERC20(weth).transferFrom(msg.sender, address(this), amount);
        balances[weth] += amount;
    }

    function getStakingBalance() external view override returns (uint256) {
        return balances[weth];
    }

    function getUnstakeRequestIds() external view override returns (uint256[] memory) {
        return _unstakeRequests.values();
    }

    function unstake(uint256 amount) external override {
        require(balances[weth] >= amount, "Insufficient balance");
        balances[weth] -= amount;

        uint256 requestId = _nextRequestId++;
        _requestAmounts[requestId] = amount;
        _unstakeRequests.add(requestId);
    }

    function claim(uint256[] memory requestIds) external override {
        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 requestId = requestIds[i];
            if (_requestAmounts[requestId] == 0) continue;
            IERC20(weth).transfer(msg.sender, _requestAmounts[requestId]);
            delete _requestAmounts[requestId];
            _unstakeRequests.remove(requestId);
        }
    }
}
