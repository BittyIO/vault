// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "./IBittyV1Vault.sol";

/**
 * @title IBittyV1PayoutOperator
 * @notice The payment-creation surface: scheduled payments, whitelisted recipients and one-off sends.
 *         Callable by the owner (DEFAULT_ADMIN_ROLE) — takes effect immediately — or the vault's
 *         payout operator (set via {IBittyV1Owner.updatePayoutOperator}) — stored pending until the owner
 *         approves it (the approve* / reviewSends functions on {IBittyV1Owner}). Implemented by {BittyV1Vault}.
 */
interface IBittyV1PayoutOperator {
    event ScheduledPaymentAdded(uint256 indexed id, IBittyV1Vault.ScheduledPayment scheduledPayment);
    event ScheduledPaymentsUpdated(uint256[] ids, IBittyV1Vault.ScheduledPayment[] scheduledPayments);
    event ScheduledPaymentsRemoved(uint256[] ids);
    event WhitelistedRecipientsSet(uint256[] ids, address[] recipients, address[] allowedAssets);
    event WhitelistedRecipientSet(uint256 indexed id, address recipient, address allowedAsset);
    event WhitelistedRecipientsRemoved(uint256[] ids);
    event SendProposed(
        uint256 indexed id, address indexed proposer, address[] recipients, address[] assets, uint256[] amounts
    );
    event SendsCancelled(uint256[] ids);
    event SendCancelled(uint256 indexed id);

    /**
     * @notice Update one or more scheduled payments.
     * @param ids The IDs of the scheduled payments to update.
     * @param scheduledPayments The scheduled payments to update.
     */
    function updateScheduledPayments(
        uint256[] calldata ids,
        IBittyV1Vault.ScheduledPayment[] calldata scheduledPayments
    ) external;

    /**
     * @notice Remove one or more scheduled payments.
     * @param ids The IDs of the scheduled payments to remove.
     */
    function removeScheduledPayments(uint256[] calldata ids) external;

    /**
     * @notice Update one or more whitelisted recipients.
     * @param ids The IDs of the whitelisted recipients to update.
     * @param recipients The addresses of the recipients to update.
     * @param allowedAssets The assets that the recipients are allowed to receive.
     */
    function updateWhitelistedRecipients(
        uint256[] calldata ids,
        address[] calldata recipients,
        address[] calldata allowedAssets
    ) external;

    /**
     * @notice Remove one or more whitelisted recipients.
     * @param ids The IDs of the whitelisted recipients to remove.
     */
    function removeWhitelistedRecipients(uint256[] calldata ids) external;

    /**
     * @notice Batch send to multiple recipients.
     * @param recipients The addresses of the recipients to send to.
     * @param assets The assets to send.
     * @param amounts The amounts to send.
     * @param stakingProtocols The staking protocols to use.
     * @param stakingAmounts The amounts from staking protocols.
     * @param lendingProtocols The lending protocols to use.
     * @param lendingAmounts The amounts from lending protocols.
     */
    function batchSend(
        address[] calldata recipients,
        address[] calldata assets,
        uint256[] calldata amounts,
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) external;

    /**
     * @notice Cancel pending one-off sends.
     * @param ids The IDs of the sends to cancel.
     */
    function cancelSends(uint256[] calldata ids) external;

    /**
     * @notice Send to a recipient.
     * @param recipient The address of the recipient.
     * @param asset The asset to send.
     * @param amount The amount to send.
     * @param stakingProtocol The staking protocol to use.
     * @param stakingAmount The amount from staking protocol.
     * @param lendingProtocol The lending protocol to use.
     * @param lendingAmount The amount from lending protocol.
     */
    function send(
        address recipient,
        address asset,
        uint256 amount,
        address stakingProtocol,
        uint256 stakingAmount,
        address lendingProtocol,
        uint256 lendingAmount
    ) external;

    /**
     * @notice Add a scheduled payment.
     * @param scheduledPayment The scheduled payment.
     * @return id The id of the scheduled payment.
     */
    function addScheduledPayment(IBittyV1Vault.ScheduledPayment calldata scheduledPayment) external returns (uint256 id);

    /**
     * @notice Add a whitelisted recipient.
     * @param recipient The address of the recipient.
     * @param allowedAsset The asset that the recipient is allowed to receive.
     * @return id The id of the whitelisted recipient.
     */
    function addWhitelistedRecipient(address recipient, address allowedAsset) external returns (uint256 id);

    /**
     * @notice Cancel a send.
     * @param id The id of the send.
     */
    function cancelSend(uint256 id) external;
}
