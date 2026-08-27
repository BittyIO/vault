// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {AccessControlUpgradeable} from "openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ContextUpgradeable} from "openzeppelin-contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "openzeppelin-contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";
import {BITTY_FORWARDER} from "./logic/Constants.sol";
import {OwnershipNotTransferable} from "./interfaces/IBittyV1Vault.sol";

abstract contract BittyV1VaultBase is AccessControlUpgradeable, ERC2771ContextUpgradeable {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;

    AssetManagerStorage internal _assetManager;
    VaultStorage internal _vault;

    address private _vaultOwner;

    constructor() ERC2771ContextUpgradeable(address(0)) {}

    function trustedForwarder() public view virtual override returns (address) {
        return BITTY_FORWARDER;
    }

    function _msgSender()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    function grantRole(bytes32, address) public virtual override {
        revert OwnershipNotTransferable();
    }

    function revokeRole(bytes32, address) public virtual override {
        revert OwnershipNotTransferable();
    }

    function renounceRole(bytes32, address) public virtual override {
        revert OwnershipNotTransferable();
    }

    function owner() public view virtual returns (address) {
        return _vaultOwner;
    }

    function defaultAdmin() public view virtual returns (address) {
        return _vaultOwner;
    }

    function _initOwner(address owner_) internal {
        _vaultOwner = owner_;
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
    }

    function _renounceOwner() internal {
        address current = _vaultOwner;
        _vaultOwner = address(0);
        _revokeRole(DEFAULT_ADMIN_ROLE, current);
    }
}
