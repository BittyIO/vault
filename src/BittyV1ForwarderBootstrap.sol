// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

error NotOwner();

interface IGuardOwner {
    function getAddress(bytes32 key) external view returns (address);
}

/**
 * @title BittyV1ForwarderBootstrap
 * @notice The implementation the forwarder proxy is BORN with, and leaves in the same transaction.
 *
 *         The forwarder is a compile-time constant in every vault, so its address moving costs a new
 *         vault implementation and a fresh deploy of the whole stack. Being born on a CONSTANT bootstrap
 *         takes the forwarder's build out of its own address: the forwarder proxy sits at one address
 *         forever, and a later change to the relay logic is an upgrade rather than a migration. It also
 *         keeps EIP-712 signatures valid, since the domain binds to the verifying contract.
 *
 * @dev DELIBERATELY self-contained: it imports nothing project-local. The guard address and owner key
 *      are literals, and the guard is reached through a minimal in-file interface — so neither
 *      {Constants} nor {IBittyV1Guard} is in this contract's metadata source set. A bootstrap's address
 *      is the hash of its whole init code (including that metadata), so this is what guarantees the
 *      address is unchanged as long as THIS file (and OpenZeppelin) is unchanged, no matter what the
 *      rest of the codebase does. The same reasoning as BittyV1VaultBootstrap.
 */
contract BittyV1ForwarderBootstrap is UUPSUpgradeable {
    address private constant GUARD = 0x000000000F5fcD35885BfE4c700042cE7cb39554;
    bytes32 private constant OWNER_KEY = keccak256("bitty.owner");

    /**
     * @dev Gated on the guard's configured owner: the proxy address is reproducible on every chain, so
     *      anyone could otherwise race the deploy on a chain Bitty has not reached yet and hand the
     *      forwarder an implementation of their own. An unconfigured guard (owner 0) fails closed.
     */
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != IGuardOwner(GUARD).getAddress(OWNER_KEY)) revert NotOwner();
    }
}
