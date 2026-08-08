// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";

contract MockIntentProtocol is IBittyV1IntentProtocol {
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

    function name() external pure override returns (string memory) {
        return "MockIntent";
    }

    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    function isValidSignature(bytes32, bytes memory) external pure override returns (bytes4) {
        return 0x1626ba7e;
    }
}
