// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ContextUpgradeable} from "openzeppelin-contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "openzeppelin-contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";
import {BITTY_FORWARDER} from "./logic/Constants.sol";
import {OwnershipNotRenounceable} from "./interfaces/IBittyV1Vault.sol";
import {Ownable2StepUpgradeable} from "openzeppelin-contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

abstract contract BittyV1VaultBase is ERC2771ContextUpgradeable, Ownable2StepUpgradeable {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;

    AssetManagerStorage internal _assetManager;
    VaultStorage internal _vault;

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

    /**
     * @dev Dropping ownership goes through {IBittyV1Owner-renounceVaultOwnership}, which first proves
     *      a locked escape route exists. This inherited entry point would skip that proof.
     */
    function renounceOwnership() public pure override {
        revert OwnershipNotRenounceable();
    }

    function _initOwner(address owner_) internal {
        __Ownable_init(owner_);
    }

    function _renounceOwner() internal {
        _transferOwnership(address(0));
    }
}
