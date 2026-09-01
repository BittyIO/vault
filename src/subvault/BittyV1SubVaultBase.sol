// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1AccountBase} from "../BittyV1AccountBase.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BittyStorage} from "../logic/BittyStorage.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {ImplementationNotRegistered} from "../interfaces/IBittyV1Vault.sol";
import {NotParentVault} from "../interfaces/IBittyV1SubVault.sol";
import {BITTY_GUARD} from "../logic/Constants.sol";

/**
 * @title BittyV1SubVaultBase
 * @notice The sub vault's base: 1-step ownership (the parent is the backstop, so a bad sub owner is
 *         recoverable) and UUPS upgrades driven by the PARENT, not the sub owner — to a guard-blessed
 *         implementation, immediately (the guard holds the timelock). A sub owner can never upgrade its
 *         own code, which would let it add an exfiltration path and break the payout monopoly.
 */
abstract contract BittyV1SubVaultBase is BittyV1AccountBase, UUPSUpgradeable {
    modifier onlyParent() {
        if (msg.sender != BittyStorage.subVault().vault) revert NotParentVault();
        _;
    }

    function _authorizeUpgrade(address newImpl) internal override {
        if (msg.sender != BittyStorage.subVault().vault) revert NotParentVault();
        if (!IBittyV1Guard(BITTY_GUARD).isImplementationRegistered(newImpl)) {
            revert ImplementationNotRegistered();
        }
    }
}
