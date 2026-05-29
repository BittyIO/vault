// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Create2} from "openzeppelin-contracts/contracts/utils/Create2.sol";
import {GnosisSafeProxy} from "safe-smart-account/contracts/proxies/GnosisSafeProxy.sol";
import {MockSafe} from "./MockSafe.sol";

/// @notice Deploys {MockSafe} via CREATE2 so the same setup + saltNonce yields the same address.
contract MockSafeProxyFactory {
    function createProxyWithNonce(address, bytes memory initializer, uint256 saltNonce)
        external
        returns (GnosisSafeProxy proxy)
    {
        bytes32 deploySalt = keccak256(abi.encodePacked(initializer, saltNonce));
        bytes memory creationCode = type(MockSafe).creationCode;
        bytes32 bytecodeHash = keccak256(creationCode);

        address predicted = Create2.computeAddress(deploySalt, bytecodeHash, address(this));
        if (predicted.code.length == 0) {
            predicted = Create2.deploy(0, deploySalt, creationCode);
            (bool success,) = predicted.call(initializer);
            require(success, "MockSafe setup failed");
        }
        proxy = GnosisSafeProxy(payable(predicted));
    }
}
