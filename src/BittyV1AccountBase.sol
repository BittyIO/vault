// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ContextUpgradeable} from "openzeppelin-contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "openzeppelin-contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MulticallUpgradeable} from "openzeppelin-contracts-upgradeable/utils/MulticallUpgradeable.sol";
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
}
