// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {VaultAlreadyActivated} from "./interfaces/IBittyV1VaultFactory.sol";

/**
 * @title BittyV1VaultBootstrap
 * @notice The implementation every vault proxy is BORN with, and leaves immediately.
 *
 *         A vault's address is CREATE2 over the proxy's init code, and that init code embeds the
 *         implementation - so while the factory deployed proxies pointing straight at the current
 *         build, shipping a new build moved every owner's vault address. Anyone who had funded their
 *         counterfactual address, or written it down, was pointed somewhere else. Fixing the factory
 *         address alone did not help: the implementation was in the hash too.
 *
 *         Being born on a CONSTANT implementation takes it out of the hash. Every proxy has the same
 *         init code forever, so a vault's address depends on its owner and nothing else, and the
 *         factory upgrades it to the real build in the same transaction.
 *
 *         Deliberately NOT a beacon, which would also fix the addresses: a beacon moves every vault
 *         at once, and an owner's upgrade is theirs to decide. This keeps one ERC-1967 slot per
 *         vault, so each is upgraded when its owner says so.
 */
contract BittyV1VaultBootstrap is UUPSUpgradeable {
    /**
     * @dev OwnableUpgradeable's ERC-7201 slot, read directly rather than by inheriting it: this
     *      contract shares the vault's storage only for the length of one transaction, and needs
     *      exactly one fact out of it.
     */
    bytes32 private constant _OWNABLE_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    /**
     * @dev Permitted only while the vault is UNCLAIMED. The factory creates the proxy and upgrades it
     *      in a single transaction, so this window never spans one - and once the real
     *      implementation's initialize has set an owner, this contract is neither the implementation
     *      nor able to authorise anything.
     */
    function _authorizeUpgrade(address) internal view override {
        address owner;
        bytes32 slot = _OWNABLE_SLOT;
        assembly {
            owner := sload(slot)
        }
        if (owner != address(0)) revert VaultAlreadyActivated();
    }
}
