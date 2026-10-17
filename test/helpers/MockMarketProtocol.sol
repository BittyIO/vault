// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1MarketTradeProtocol} from "protocol-contracts/src/interfaces/IBittyV1MarketTradeProtocol.sol";

/**
 * @dev A market-trade protocol that accepts any swap and moves nothing, for tests that only need the
 *      vault to reach the protocol.
 */
contract MockMarketProtocol is IBittyV1MarketTradeProtocol {
    function protocolLineage() external pure returns (bytes32) {
        return keccak256("bitty.mock.marketTrade");
    }

    function protocolVersion() external pure returns (uint256) {
        return 1_000_000;
    }

    function versionName() external pure returns (string memory) {
        return "1.0.0";
    }

    function initialize(address) external override {}

    function swap(bytes memory, address) external payable virtual override {}

    function swapExactOut(bytes memory, address) external virtual override {}

    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        return interfaceId == type(IBittyV1MarketTradeProtocol).interfaceId || interfaceId == 0x01ffc9a7;
    }
}
