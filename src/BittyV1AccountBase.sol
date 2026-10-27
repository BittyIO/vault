// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ContextUpgradeable} from "openzeppelin-contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "openzeppelin-contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MulticallUpgradeable} from "openzeppelin-contracts-upgradeable/utils/MulticallUpgradeable.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {BITTY_FORWARDER} from "./logic/Constants.sol";
import {BittyStorage, VaultStorage} from "./logic/BittyStorage.sol";

/**
 * @title BittyV1AccountBase
 * @notice The shared context every account and the shared DeFi facet inherit: ERC-2771 relaying against
 *         the fixed Bitty forwarder, and the vault's authority. The owner is read from a FIXED ERC-7201
 *         slot ({BittyStorage}), which is what lets the delegatecalled facet's `_msgSender() == owner()`
 *         resolve to the vault's owner.
 * @dev `owner()` is overridden here rather than on the vault, because a matured handover takes effect
 *      on a clock and both contracts have to agree about it — see the override below.
 *
 *      Batching lives here, next to the context it depends on. {MulticallUpgradeable} self-delegatecalls each entry, so `msg.sender` and storage
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
     * @dev A contract that re-enters during the activation window is not the activator, so it gets no
     *      suffix and is attributed to itself.
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
     * @dev The owner is appended to each entry as the ERC-2771 suffix, which is what {_msgSender}
     *      reads while `msg.sender` (the activator) is trusted. Reverts bubble up, so an activation
     *      with a failing entry leaves no account behind.
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

    error PayRelayerFeeNotRelayable();

    bytes4 private constant _PAY_RELAYER_FEE_SELECTOR = bytes4(keccak256("payRelayerFee(address,uint256)"));

    function multicall(bytes[] calldata data)
        external
        virtual
        override(MulticallUpgradeable)
        returns (bytes[] memory results)
    {
        // Same ERC-2771 suffix handling as OZ's MulticallUpgradeable, with the payRelayerFee guard added.
        bytes memory context =
            msg.sender == _msgSender() ? new bytes(0) : msg.data[msg.data.length - _contextSuffixLength():];
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; ++i) {
            if (data[i].length >= 4 && bytes4(data[i][:4]) == _PAY_RELAYER_FEE_SELECTOR) {
                revert PayRelayerFeeNotRelayable();
            }
            results[i] = Address.functionDelegateCall(address(this), bytes.concat(data[i], context));
        }
    }

    function owner() public view virtual override returns (address) {
        VaultStorage storage $ = BittyStorage.vault();
        uint256 readyAt = $.ownershipReadyAt;
        if (readyAt != 0 && block.timestamp >= readyAt) return $.pendingOwner;
        return $.vaultOwner;
    }

    function _transferOwnership(address newOwner) internal virtual override {
        VaultStorage storage $ = BittyStorage.vault();
        address previous = $.vaultOwner;
        $.vaultOwner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
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
