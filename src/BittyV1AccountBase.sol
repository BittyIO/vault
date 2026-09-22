// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ContextUpgradeable} from "openzeppelin-contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "openzeppelin-contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MulticallUpgradeable} from "openzeppelin-contracts-upgradeable/utils/MulticallUpgradeable.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {BITTY_FORWARDER} from "./logic/Constants.sol";

/**
 * @title BittyV1AccountBase
 * @notice The shared context every account and the shared DeFi facet inherit: ERC-2771 relaying against
 *         the fixed Bitty forwarder, plus {OwnableUpgradeable} so `owner()` lives at OZ's fixed ERC-7201
 *         slot. That fixed slot is what lets the delegatecalled facet's `_msgSender() == owner()` resolve
 *         to the *host's* owner — the main owner in the main vault, the sub owner in a sub vault.
 * @dev The main vault layers {Ownable2StepUpgradeable} on top for 2-step transfer; the sub vault keeps
 *      plain 1-step ownership driven by its parent. Both share the same `owner()` slot, so the facet is
 *      indifferent to which host it runs in.
 *
 *      Batching lives here rather than on either account, so a sub vault gets it on the same terms as
 *      the main one. {MulticallUpgradeable} self-delegatecalls each entry, so `msg.sender` and storage
 *      stay the caller's throughout and every call is authorised exactly as it would be alone —
 *      batching grants nothing. It also re-appends the ERC-2771 sender suffix to each sub-call, which
 *      a hand-rolled loop would drop, silently turning a relayed batch into calls attributed to the
 *      forwarder.
 *
 *      The UPGRADEABLE variant specifically: the non-upgradeable {Multicall} pulls in plain `Context`
 *      and collides with `ContextUpgradeable` here, which is what dropped batching in the first place.
 */
abstract contract BittyV1AccountBase is ERC2771ContextUpgradeable, OwnableUpgradeable, MulticallUpgradeable {
    /**
     * @dev The activation window. While an account is being initialised, the address that initialised
     *      it (the factory) is honoured as a trusted forwarder, so the calls it hands over run with the
     *      OWNER's authority exactly as a relayed call would. TRANSIENT on purpose: the window opens
     *      inside `initialize` and is closed before it returns, and the slot is wiped at the end of the
     *      transaction regardless - so a factory upgrade can never impersonate the owner of a vault
     *      that already exists. Not an ERC-7201 slot, and never part of the storage layout.
     */
    bytes32 private constant _ACTIVATOR_TSLOT = keccak256("bitty.account.activator.transient");

    constructor() ERC2771ContextUpgradeable(address(0)) {}

    function trustedForwarder() public view virtual override returns (address) {
        return BITTY_FORWARDER;
    }

    /**
     * @dev The fixed forwarder, plus whoever opened the activation window - and only for as long as
     *      it is open. A contract that re-enters during the window is not the activator, so it gets
     *      no suffix and is attributed to itself.
     */
    function isTrustedForwarder(address forwarder) public view virtual override returns (bool) {
        if (forwarder == BITTY_FORWARDER) return true;
        address activator;
        bytes32 slot = _ACTIVATOR_TSLOT;
        assembly {
            activator := tload(slot)
        }
        return activator != address(0) && forwarder == activator;
    }

    /**
     * @dev Run `calls` through this account as `owner_`, in the caller's activation window. Each entry
     *      is self-delegatecalled with the owner appended as the ERC-2771 suffix, which is what
     *      {_msgSender} reads while `msg.sender` (the activator) is trusted. Reverts bubble up, so an
     *      activation with a failing entry leaves no account behind.
     */
    function _runAsOwner(address owner_, bytes[] calldata calls) internal {
        bytes32 slot = _ACTIVATOR_TSLOT;
        assembly {
            tstore(slot, caller())
        }
        for (uint256 i; i < calls.length; ++i) {
            Address.functionDelegateCall(address(this), bytes.concat(calls[i], bytes20(owner_)));
        }
        assembly {
            tstore(slot, 0)
        }
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
}
