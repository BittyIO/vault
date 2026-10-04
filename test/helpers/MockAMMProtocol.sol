// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1MarketTradeProtocol} from "protocol-contracts/src/interfaces/IBittyV1MarketTradeProtocol.sol";
import {IBittyV1MarketMakerProtocol} from "protocol-contracts/src/interfaces/IBittyV1MarketMakerProtocol.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev A single mock that answers BOTH split interfaces, so a test can deploy one instance and register it
 *      as a market-trade protocol, another and register it as a market-maker protocol. The guard gates on
 *      the registered category, not on which methods exist, so implementing both is harmless.
 */
contract MockAMMProtocol is IBittyV1MarketTradeProtocol, IBittyV1MarketMakerProtocol {
    function protocolLineage() external pure returns (bytes32) {
        return keccak256("bitty.mock.amm");
    }

    function protocolVersion() external pure returns (uint256) {
        return 1_000_000;
    }

    function versionName() external pure returns (string memory) {
        return "1.0.0";
    }

    using SafeERC20 for IERC20;

    uint256 public decreaseLiquidityCallCount;
    uint256 public removeLiquidityCallCount;
    bytes public lastDecreaseData;
    bytes public lastRemoveData;

    function initialize(address) external override {}

    function addLiquidity(bytes memory) external override {}

    function swap(bytes memory, address) external payable override {}

    function swapExactOut(bytes memory, address) external override {}

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

    function positionManager() external view virtual override returns (address) {
        return address(0);
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        return interfaceId == type(IBittyV1MarketTradeProtocol).interfaceId
            || interfaceId == type(IBittyV1MarketMakerProtocol).interfaceId || interfaceId == 0x01ffc9a7;
    }
}
