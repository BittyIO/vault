// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";

contract MockIntentProtocol is IBittyV1IntentProtocol {
    function protocolLineage() external pure returns (bytes32) {
        return keccak256("bitty.mock.intent");
    }

    function protocolVersion() external pure returns (uint256) {
        return 1_000_000;
    }

    function versionName() external pure returns (string memory) {
        return "1.0.0";
    }

    address public owner;
    address public settlement;
    address public vaultRelayer;

    function setEndpoints(address settlement_, address vaultRelayer_) external {
        settlement = settlement_;
        vaultRelayer = vaultRelayer_;
    }

    function initialize(address newOwner) external override {
        owner = newOwner;
    }

    function isValidSignature(bytes32, bytes memory) external pure override returns (bytes4) {
        return 0x1626ba7e;
    }

    /**
     * @dev Declares its category so the guard will register it; `virtual` so subclasses can differ.
     */
    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        return interfaceId == type(IBittyV1IntentProtocol).interfaceId || interfaceId == 0x01ffc9a7;
    }
}
