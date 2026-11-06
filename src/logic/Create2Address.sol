// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {TRON_MAINNET_CHAIN_ID, TRON_NILE_CHAIN_ID} from "./Constants.sol";

/**
 * @title Create2Address
 * @notice Where CREATE2 puts a contract, on the VM this code is actually running on.
 * @dev The TVM hashes a CREATE2 address with a 0x41 prefix where the EVM uses 0xff:
 *      keccak256(0x41 ‖ deployer ‖ salt ‖ keccak256(initCode)). OpenZeppelin's {Create2} hard-codes
 *      0xff, so on TRON it names an address nothing is ever deployed at — and a counterfactual vault
 *      address is one users fund before activation, so a wrong prediction loses their deposit.
 *
 *      The prefix is chosen by chain id rather than fixed at 0x41 so the same build stays testable
 *      under Foundry, which runs the EVM: there the 0xff address is the true one.
 */
library Create2Address {
    function compute(bytes32 salt, bytes32 initCodeHash, address deployer) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(prefix(), deployer, salt, initCodeHash)))));
    }

    function prefix() internal view returns (bytes1) {
        return isTron() ? bytes1(0x41) : bytes1(0xff);
    }

    function isTron() internal view returns (bool) {
        return block.chainid == TRON_MAINNET_CHAIN_ID || block.chainid == TRON_NILE_CHAIN_ID;
    }
}
