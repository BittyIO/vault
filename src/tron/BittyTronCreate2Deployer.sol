// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Create2Address} from "../logic/Create2Address.sol";

error Create2Failed();

/**
 * @title BittyTronCreate2Deployer
 * @notice TRON's stand-in for the EVM's canonical CREATE2 deployer (0x4e59…956C), which does not
 *         exist there: deploys `initCode` at the address CREATE2 gives `salt` and `initCode` here.
 * @dev Permissionless, like the original. That is safe for the same reason it is on the EVM: every
 *      address is a pure function of the init code, so whoever sends the deployment can only ever put
 *      the exact contract the deploy expects there — the bootstraps then gate their one upgrade on
 *      the DEPLOYER themselves. A typed function rather than the original's raw calldata, so TronWeb
 *      can call it through an ABI.
 *
 *      Its own address is NOT reproducible across TRON networks: a top-level deployment's address is
 *      derived from the transaction, not a nonce. Every address below it is, given this one.
 */
contract BittyTronCreate2Deployer {
    event Deployed(address indexed deployed, bytes32 indexed salt);

    function deploy(bytes32 salt, bytes calldata initCode) external payable returns (address deployed) {
        bytes memory code = initCode;
        assembly ("memory-safe") {
            deployed := create2(callvalue(), add(code, 0x20), mload(code), salt)
        }
        if (deployed == address(0)) revert Create2Failed();
        emit Deployed(deployed, salt);
    }

    function computeAddress(bytes32 salt, bytes32 initCodeHash) external view returns (address) {
        return Create2Address.compute(salt, initCodeHash, address(this));
    }
}
