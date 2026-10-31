// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1AccountBase} from "./BittyV1AccountBase.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnershipNotRenounceable, ImplementationNotRegistered, VaultNotNewer} from "./interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "./logic/Constants.sol";
import {LockLib} from "./logic/LockLib.sol";
import {IBittyV1Guard, IMPLEMENTATION_VAULT} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

/**
 * @title BittyV1VaultBase
 * @notice The main vault's base: ownership and owner-controlled UUPS upgrades. A handover runs on a
 *         clock — started in one call and complete when the vault's timelock expires, with no
 *         acceptance step — see {BittyV1Vault-transferOwnership} for why a wait beats a second
 *         signature against a key
 *         that has leaked, and {BittyV1Vault-owner} for how authority moves without a transaction.
 *         Ownership cannot be given up: a vault with nobody answering for it was replaced by
 *         {BittyV1Vault-foreverLock}, which freezes the same risk surface while leaving the owner
 *         able to use what is left.
 *
 *         Upgrades are instant, and may only move forward. The target must be a guard-blessed
 *         implementation and the guard timelocks the blessing globally, so the delay belongs there
 *         rather than here: it is the code that has to prove itself, not the owner. A vault stays
 *         upgradeable for life, with no opt-out — except while it is locked: an emergency lock pauses
 *         upgrades until it is released, and a forever lock freezes the code for good.
 */
abstract contract BittyV1VaultBase is BittyV1AccountBase, UUPSUpgradeable {
    uint256 private constant _VERSION = 1 * 1_000_000 + 0 * 1_000 + 7;

    function vaultVersion() external pure virtual returns (uint256) {
        return _VERSION;
    }

    function versionName() external pure returns (string memory) {
        return string.concat(
            Strings.toString(_VERSION / 1_000_000),
            ".",
            Strings.toString((_VERSION / 1_000) % 1_000),
            ".",
            Strings.toString(_VERSION % 1_000)
        );
    }

    function upgrade(address newImpl) external {
        upgradeToAndCall(newImpl, "");
    }

    function _authorizeUpgrade(address newImpl) internal view override {
        _checkOwner();
        LockLib.requireNotLocked();
        if (!IBittyV1Guard(BITTY_GUARD).isImplementationRegisteredFor(newImpl, IMPLEMENTATION_VAULT)) {
            revert ImplementationNotRegistered();
        }
        if (BittyV1VaultBase(payable(newImpl)).vaultVersion() <= this.vaultVersion()) revert VaultNotNewer();
    }

    function _msgSender() internal view override returns (address) {
        return BittyV1AccountBase._msgSender();
    }

    function _msgData() internal view override returns (bytes calldata) {
        return BittyV1AccountBase._msgData();
    }

    function _contextSuffixLength() internal view override returns (uint256) {
        return BittyV1AccountBase._contextSuffixLength();
    }

    function renounceOwnership() public pure override {
        revert OwnershipNotRenounceable();
    }
}
