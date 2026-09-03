// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

error NotDeployer();

/**
 * @title BittyV1ForwarderBootstrap
 * @notice The implementation the forwarder proxy is BORN with, and leaves in the same transaction.
 *
 *         The forwarder is a compile-time constant in every vault, so its address moving costs a new
 *         vault implementation, a new factory, and a fresh vanity mine for both - which is exactly what
 *         happened when the forwarder gained two-step ownership after its first deployment. A proxy's
 *         init code embeds its implementation, so pointing one straight at the build would carry that
 *         cost forward to every future change.
 *
 *         Being born on a CONSTANT implementation takes the build out of the hash. The forwarder's
 *         address is then the same on every chain at every version, and a later change to the relay
 *         logic is an upgrade rather than a migration of the whole vault stack. It also keeps EIP-712
 *         signatures valid: the domain binds to the verifying contract, so a moving address would
 *         invalidate every signature ever made for this forwarder.
 *
 *         The same reasoning as BittyV1VaultBootstrap and BittyV1GuardBootstrap.
 */
contract BittyV1ForwarderBootstrap is UUPSUpgradeable {
    address private constant DEPLOYER = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    /**
     * @dev The deployer, by tx.origin, for the same reason the forwarder's own initialize uses it: the
     *      proxy address is reproducible on every chain, so anyone could otherwise race the deploy on a
     *      chain Bitty has not reached yet and hand the forwarder an implementation of their own. The
     *      forwarder's owner takes over the moment this contract stops being the implementation.
     */
    function _authorizeUpgrade(address) internal view override {
        if (tx.origin != DEPLOYER) revert NotDeployer();
    }
}
