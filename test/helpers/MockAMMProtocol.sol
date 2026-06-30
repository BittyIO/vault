// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1AMMProtocol} from "protocol-contracts/src/interfaces/IBittyV1AMMProtocol.sol";

contract MockAMMProtocol is IBittyV1AMMProtocol {
    uint256 public decreaseLiquidityCallCount;
    uint256 public removeLiquidityCallCount;
    bytes public lastDecreaseData;
    bytes public lastRemoveData;

    function initialize(address) external override {}

    function swap(bytes memory) external payable override {}

    function swapExactOut(bytes memory) external override {}

    function addLiquidity(bytes memory) external override {}

    function removeLiquidity(bytes memory data) external override {
        removeLiquidityCallCount++;
        lastRemoveData = data;
    }

    function decreaseLiquidity(bytes memory data) external override {
        decreaseLiquidityCallCount++;
        lastDecreaseData = data;
    }

    function claimAMMFees(bytes memory) external override {}

    function getLiquidity(bytes memory) external pure override returns (uint256) {
        return 0;
    }
}
