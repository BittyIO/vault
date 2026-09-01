// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AddressZero,
    AmountIsZero,
    ArrayLengthMismatch,
    IBittyV1Vault,
    WhitelistedRecipientNotFound,
    WhitelistedRecipientAssetNotAllowed,
    PaymentNotApproved,
    NotPendingApproval,
    NotProposalOwner,
    WhitelistedRecipientContentMismatch
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {IBittyV1PayoutOperator} from "../interfaces/IBittyV1PayoutOperator.sol";
import {BittyStorage, VaultStorage} from "./BittyStorage.sol";
import {PaymentCore} from "./PaymentCore.sol";
import {TimelockLib} from "./TimelockLib.sol";

/**
 * @title WhitelistLogic
 * @notice Whitelisted recipients: add / update / review / remove, and the protected payout to a
 *         pre-approved recipient. Split out of {PaymentLogic}; shares payout/protection via {PaymentCore}.
 */
library WhitelistLogic {
    function addWhitelistedRecipientOne(address recipient, address allowedAsset, bool byOwner, address sender)
        external
        returns (uint256 id)
    {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        uint256 deadline =
            PaymentCore.protectionDeadline(TimelockLib.effective(vaultStorage.riskConfig.newPaymentProtection));
        id = _addWhitelistedRecipient(vaultStorage, recipient, allowedAsset, byOwner, deadline, sender);
        emit IBittyV1PayoutOperator.WhitelistedRecipientSet(id, recipient, allowedAsset);
    }

    function _addWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        address recipient,
        address allowedAsset,
        bool byOwner,
        uint256 protectionDeadline,
        address sender
    ) private returns (uint256 id) {
        if (recipient == address(0)) revert AddressZero();
        id = ++vaultStorage.nextWhitelistedRecipientId;
        vaultStorage.whitelistedRecipients[id] =
            IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset});
        if (!byOwner) vaultStorage.whitelistedRecipientPendingProposer[id] = sender;
        vaultStorage.whitelistedRecipientEffectiveAt[id] = protectionDeadline;
    }

    function updateWhitelistedRecipients(
        uint256[] calldata ids,
        address[] calldata recipients,
        address[] calldata allowedAssets,
        bool byOwner,
        address sender
    ) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        if (ids.length != recipients.length || recipients.length != allowedAssets.length) revert ArrayLengthMismatch();
        uint256 protectionDeadline =
            PaymentCore.protectionDeadline(TimelockLib.effective(vaultStorage.riskConfig.newPaymentProtection));
        for (uint256 i; i < ids.length; ++i) {
            _updateWhitelistedRecipient(
                vaultStorage, ids[i], recipients[i], allowedAssets[i], byOwner, protectionDeadline, sender
            );
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.WhitelistedRecipientsSet(ids, recipients, allowedAssets);
    }

    function _updateWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        uint256 id,
        address recipient,
        address allowedAsset,
        bool byOwner,
        uint256 protectionDeadline,
        address sender
    ) private {
        if (recipient == address(0)) revert AddressZero();
        if (vaultStorage.whitelistedRecipients[id].recipient == address(0)) revert WhitelistedRecipientNotFound();
        if (byOwner) {
            delete vaultStorage.whitelistedRecipientPendingProposer[id];
        } else if (vaultStorage.whitelistedRecipientPendingProposer[id] != sender) {
            revert NotProposalOwner();
        }
        vaultStorage.whitelistedRecipients[id] =
            IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset});
        vaultStorage.whitelistedRecipientEffectiveAt[id] = protectionDeadline;
    }

    function reviewWhitelistedRecipients(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds,
        address sender
    ) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        if (approveIds.length != expectedHashes.length) revert ArrayLengthMismatch();
        for (uint256 i; i < approveIds.length; ++i) {
            _approveWhitelistedRecipient(vaultStorage, approveIds[i], expectedHashes[i]);
        }
        for (uint256 i; i < cancelIds.length; ++i) {
            _removeWhitelistedRecipient(vaultStorage, cancelIds[i], true, sender);
        }
        if (approveIds.length > 0) emit IBittyV1Owner.WhitelistedRecipientsApproved(approveIds);
        if (cancelIds.length > 0) emit IBittyV1PayoutOperator.WhitelistedRecipientsRemoved(cancelIds);
    }

    function _approveWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, bytes32 expectedHash) private {
        IBittyV1Vault.WhitelistedRecipient memory recipient = vaultStorage.whitelistedRecipients[id];
        if (recipient.recipient == address(0)) revert WhitelistedRecipientNotFound();
        if (vaultStorage.whitelistedRecipientPendingProposer[id] == address(0)) revert NotPendingApproval();
        if (keccak256(abi.encode(recipient)) != expectedHash) revert WhitelistedRecipientContentMismatch();
        delete vaultStorage.whitelistedRecipientPendingProposer[id];
    }

    function removeWhitelistedRecipients(uint256[] calldata ids, bool byOwner, address sender) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        for (uint256 i; i < ids.length; ++i) {
            _removeWhitelistedRecipient(vaultStorage, ids[i], byOwner, sender);
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.WhitelistedRecipientsRemoved(ids);
    }

    function _removeWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, bool byOwner, address sender)
        private
    {
        address recipient = vaultStorage.whitelistedRecipients[id].recipient;
        if (recipient == address(0)) revert WhitelistedRecipientNotFound();
        if (!byOwner && vaultStorage.whitelistedRecipientPendingProposer[id] != sender) revert NotProposalOwner();
        delete vaultStorage.whitelistedRecipients[id];
        delete vaultStorage.whitelistedRecipientPendingProposer[id];
        delete vaultStorage.whitelistedRecipientEffectiveAt[id];
    }

    function sendToWhitelistedRecipientOne(uint256 id, address asset, uint256 amount) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        address recipient = _sendToWhitelistedRecipient(vaultStorage, id, asset, amount);
        emit IBittyV1Owner.WhitelistedRecipientPaid(id, recipient, asset, amount);
    }

    function _sendToWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, address asset, uint256 amount)
        private
        returns (address recipient)
    {
        if (amount == 0) revert AmountIsZero();
        IBittyV1Vault.WhitelistedRecipient memory entry = vaultStorage.whitelistedRecipients[id];
        if (entry.recipient == address(0)) revert WhitelistedRecipientNotFound();
        if (vaultStorage.whitelistedRecipientPendingProposer[id] != address(0)) revert PaymentNotApproved();
        if (entry.allowedAsset != address(0) && asset != entry.allowedAsset) {
            revert WhitelistedRecipientAssetNotAllowed();
        }
        PaymentCore.requireProtectionElapsed(vaultStorage.whitelistedRecipientEffectiveAt[id]);
        PaymentCore.payOut(vaultStorage, asset, amount, entry.recipient);
        recipient = entry.recipient;
    }

    function getWhitelistedRecipients(uint256[] calldata ids)
        external
        view
        returns (address[] memory recipients, address[] memory allowedAssets)
    {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        recipients = new address[](ids.length);
        allowedAssets = new address[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            IBittyV1Vault.WhitelistedRecipient memory entry = vaultStorage.whitelistedRecipients[ids[i]];
            recipients[i] = entry.recipient;
            allowedAssets[i] = entry.allowedAsset;
        }
    }
}
