// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

error NotOwner();

interface IGuardOwner {
    function getAddress(bytes32 key) external view returns (address);
}

/**
 * @title BittyV1VaultFactoryBootstrap
 * @notice The implementation the factory proxy is BORN with, and leaves in the same transaction.
 *
 *         The factory is the CREATE2 deployer of every vault, so its address is baked into every vault
 *         address. If the factory were a plain contract, changing its logic would move the factory —
 *         and relocate every owner's vault. Being born on a CONSTANT bootstrap takes the factory's build
 *         out of its own address: the factory proxy sits at one address forever, and new factory logic
 *         is an upgrade rather than a new deployment, so vault addresses survive every future version.
 *
 * @dev DELIBERATELY self-contained: it imports nothing project-local. The guard address and owner key
 *      are literals, and the guard is reached through a minimal in-file interface — so neither
 *      {Constants} nor {IBittyV1Guard} is in this contract's metadata source set. A bootstrap's address
 *      is the hash of its whole init code (including that metadata), so this is what guarantees the
 *      address is unchanged as long as THIS file (and OpenZeppelin) is unchanged, no matter what the
 *      rest of the codebase does. The same reasoning as BittyV1VaultBootstrap / BittyV1ForwarderBootstrap.
 */
contract BittyV1VaultFactoryBootstrap is UUPSUpgradeable {
    address private constant GUARD = 0x000000000F5fcD35885BfE4c700042cE7cb39554;
    bytes32 private constant OWNER_KEY = keccak256("bitty.owner");

    /**
     * @dev Only the Bitty owner may perform the first upgrade off the bootstrap; the factory's own owner
     *      (the same guard value) takes over the moment this contract stops being the implementation. An
     *      unconfigured guard (owner 0) fails closed — no upgrade at all.
     */
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != IGuardOwner(GUARD).getAddress(OWNER_KEY)) revert NotOwner();
    }
}
