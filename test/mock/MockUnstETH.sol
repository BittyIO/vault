// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IUnstETH} from "../../src/libs/Lido.sol";
import {ERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockUnstETH is ERC721, IUnstETH {
    uint256 private _nextRequestId = 1;
    mapping(uint256 => WithdrawalRequestStatus) private _withdrawalRequests;
    mapping(uint256 => uint256) private _requestAmounts; // requestId => stETH amount
    address public stETH;

    constructor(address _stETH) ERC721("Mock unstETH", "unstETH") {
        stETH = _stETH;
    }

    function _baseURI() internal pure override returns (string memory) {
        return "";
    }

    function requestWithdrawals(uint256[] calldata _amounts, address _owner)
        external
        override
        returns (uint256[] memory requestIds)
    {
        require(_amounts.length > 0, "Empty amounts");
        require(_owner != address(0), "Invalid owner");

        // Transfer stETH from caller
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _amounts.length; i++) {
            totalAmount += _amounts[i];
        }
        IERC20(stETH).transferFrom(msg.sender, address(this), totalAmount);

        requestIds = new uint256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; i++) {
            uint256 requestId = _nextRequestId++;
            requestIds[i] = requestId;
            _requestAmounts[requestId] = _amounts[i];
            _withdrawalRequests[requestId] = WithdrawalRequestStatus({
                amountOfStETH: _amounts[i],
                amountOfShares: _amounts[i], // 1:1 for simplicity
                owner: _owner,
                timestamp: block.timestamp,
                isFinalized: false,
                isClaimed: false
            });
            _mint(_owner, requestId);
        }
        return requestIds;
    }

    function getWithdrawalStatus(uint256[] calldata _requestIds)
        external
        view
        override
        returns (WithdrawalRequestStatus[] memory statuses)
    {
        statuses = new WithdrawalRequestStatus[](_requestIds.length);
        for (uint256 i = 0; i < _requestIds.length; i++) {
            statuses[i] = _withdrawalRequests[_requestIds[i]];
        }
        return statuses;
    }

    function claimWithdrawal(uint256 _requestId) external override {
        WithdrawalRequestStatus memory status = _withdrawalRequests[_requestId];
        require(status.owner == msg.sender, "Not owner");
        require(status.isFinalized, "Not finalized");
        require(!status.isClaimed, "Already claimed");

        _withdrawalRequests[_requestId].isClaimed = true;
        uint256 amount = _requestAmounts[_requestId];

        // Burn the stETH that was locked
        IERC20(stETH).transfer(address(0xdead), amount);

        // Transfer ETH back (1:1 with stETH)
        // Note: In real Lido, this would come from the withdrawal pool
        // For mock, we need to ensure the contract has ETH balance
        require(address(this).balance >= amount, "Insufficient ETH balance");
        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");

        _burn(_requestId);
    }

    // Helper function to finalize a withdrawal request (for testing)
    function finalizeWithdrawal(uint256 _requestId) external {
        require(_withdrawalRequests[_requestId].amountOfStETH > 0, "Request not found");
        require(!_withdrawalRequests[_requestId].isFinalized, "Already finalized");
        _withdrawalRequests[_requestId].isFinalized = true;
    }

    receive() external payable {}
}

