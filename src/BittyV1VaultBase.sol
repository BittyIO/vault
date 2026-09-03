// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1AccountBase} from "./BittyV1AccountBase.sol";
import {ContextUpgradeable} from "openzeppelin-contracts-upgradeable/utils/ContextUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "openzeppelin-contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnershipNotRenounceable, ImplementationNotRegistered} from "./interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "./logic/Constants.sol";
import {IBittyV1Guard, IMPLEMENTATION_VAULT} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

/**
 * @title BittyV1VaultBase
 * @notice The main vault's base: 2-step ownership (a mistake is terminal — no backstop) and
 *         owner-controlled UUPS upgrades. The upgrade target must be a guard-blessed implementation; the
 *         guard timelocks the blessing globally, so there is no per-vault delay. A vault stays upgradeable
 *         for life — there is no opt-out, so a bug found later is always patchable.
 */
abstract contract BittyV1VaultBase is BittyV1AccountBase, Ownable2StepUpgradeable, UUPSUpgradeable {
    uint256 private constant _VERSION = 1 * 1_000_000 + 0 * 1_000 + 0;

    function vaultVersion() external pure returns (uint256) {
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
        if (!IBittyV1Guard(BITTY_GUARD).isImplementationRegisteredFor(newImpl, IMPLEMENTATION_VAULT)) {
            revert ImplementationNotRegistered();
        }
    }

    function _msgSender() internal view override(BittyV1AccountBase, ContextUpgradeable) returns (address) {
        return BittyV1AccountBase._msgSender();
    }

    function _msgData() internal view override(BittyV1AccountBase, ContextUpgradeable) returns (bytes calldata) {
        return BittyV1AccountBase._msgData();
    }

    function _contextSuffixLength() internal view override(BittyV1AccountBase, ContextUpgradeable) returns (uint256) {
        return BittyV1AccountBase._contextSuffixLength();
    }

    function transferOwnership(address newOwner)
        public
        override(OwnableUpgradeable, Ownable2StepUpgradeable)
        onlyOwner
    {
        Ownable2StepUpgradeable.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal override(OwnableUpgradeable, Ownable2StepUpgradeable) {
        Ownable2StepUpgradeable._transferOwnership(newOwner);
    }

    function renounceOwnership() public pure override {
        revert OwnershipNotRenounceable();
    }
}
