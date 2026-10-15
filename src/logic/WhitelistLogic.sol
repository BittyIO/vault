// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AddressZero,
    AmountIsZero,
    ArrayLengthMismatch,
    IBittyV1Vault,
    WhitelistedRecipientNotFound,
    WhitelistedRecipientAssetNotAllowed
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {BittyStorage, Deferred, VaultStorage} from "./BittyStorage.sol";
import {PaymentCore} from "./PaymentCore.sol";
import {LockLib} from "./LockLib.sol";
import {TimelockLib} from "./TimelockLib.sol";

/**
 * @title WhitelistLogic
 * @notice Whitelisted recipients: add / update / review / remove, and the protected payout to a
 *         pre-approved recipient. Split out of {PaymentLogic}; shares payout/protection via {PaymentCore}.
 */
library WhitelistLogic {
    function addWhitelistedRecipientOne(address recipient, address allowedAsset) external returns (uint256 id) {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        uint256 deadline = PaymentCore.protectionDeadline(TimelockLib.effective(vaultStorage.riskConfig.timelock));
        id = _addWhitelistedRecipient(vaultStorage, recipient, allowedAsset, deadline);
        emit IBittyV1Owner.WhitelistedRecipientSet(id, recipient, allowedAsset);
    }

    function _addWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        address recipient,
        address allowedAsset,
        uint256 protectionDeadline
    ) private returns (uint256 id) {
        if (recipient == address(0)) revert AddressZero();
        id = ++vaultStorage.nextWhitelistedRecipientId;
        vaultStorage.whitelistedRecipient[id] = recipient;
        _writeDeferred(vaultStorage, id, allowedAsset, protectionDeadline);
    }

    function _writeDeferred(VaultStorage storage vaultStorage, uint256 id, address allowedAsset, uint256 effectiveAt)
        private
    {
        vaultStorage.whitelistedRecipientDeferred[id] = Deferred({
            allowedAsset: allowedAsset,
            effectiveAt: uint64(effectiveAt),
            lockEpoch: effectiveAt == 0 ? LockLib.SETTLED : LockLib.lockEpoch()
        });
    }

    function updateWhitelistedRecipients(
        uint256[] calldata ids,
        address[] calldata recipients,
        address[] calldata allowedAssets
    ) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        if (ids.length != recipients.length || recipients.length != allowedAssets.length) revert ArrayLengthMismatch();
        uint256 protectionDeadline =
            PaymentCore.protectionDeadline(TimelockLib.effective(vaultStorage.riskConfig.timelock));
        for (uint256 i; i < ids.length; ++i) {
            _updateWhitelistedRecipient(vaultStorage, ids[i], recipients[i], allowedAssets[i], protectionDeadline);
        }
        if (ids.length > 0) emit IBittyV1Owner.WhitelistedRecipientsSet(ids, recipients, allowedAssets);
    }

    function _updateWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        uint256 id,
        address recipient,
        address allowedAsset,
        uint256 protectionDeadline
    ) private {
        if (recipient == address(0)) revert AddressZero();
        if (vaultStorage.whitelistedRecipient[id] == address(0)) revert WhitelistedRecipientNotFound();
        vaultStorage.whitelistedRecipient[id] = recipient;
        _writeDeferred(vaultStorage, id, allowedAsset, protectionDeadline);
    }

    function removeWhitelistedRecipients(uint256[] calldata ids) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        for (uint256 i; i < ids.length; ++i) {
            _removeWhitelistedRecipient(vaultStorage, ids[i]);
        }
        if (ids.length > 0) emit IBittyV1Owner.WhitelistedRecipientsRemoved(ids);
    }

    function _removeWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id) private {
        address recipient = vaultStorage.whitelistedRecipient[id];
        if (recipient == address(0)) revert WhitelistedRecipientNotFound();
        delete vaultStorage.whitelistedRecipient[id];
        delete vaultStorage.whitelistedRecipientDeferred[id];
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
        recipient = vaultStorage.whitelistedRecipient[id];
        if (recipient == address(0)) revert WhitelistedRecipientNotFound();

        Deferred memory deferred = vaultStorage.whitelistedRecipientDeferred[id];
        if (deferred.allowedAsset != address(0) && asset != deferred.allowedAsset) {
            revert WhitelistedRecipientAssetNotAllowed();
        }
        PaymentCore.requireProtectionElapsed(deferred.effectiveAt);
        if (LockLib.requireHonoured(deferred.lockEpoch, deferred.effectiveAt)) {
            vaultStorage.whitelistedRecipientDeferred[id].lockEpoch = LockLib.SETTLED;
        }

        PaymentCore.payOut(vaultStorage, asset, amount, recipient);
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
            recipients[i] = vaultStorage.whitelistedRecipient[ids[i]];
            allowedAssets[i] = vaultStorage.whitelistedRecipientDeferred[ids[i]].allowedAsset;
        }
    }
}
