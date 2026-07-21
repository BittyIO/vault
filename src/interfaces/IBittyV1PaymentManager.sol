// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "./IBittyV1Vault.sol";

/**
 * @title IBittyV1PaymentManager
 * @notice The payment-creation surface: scheduled payments, whitelisted recipients and one-off sends.
 *         Callable by the owner (DEFAULT_ADMIN_ROLE) — takes effect immediately — or a payment manager
 *         (PAYMENT_MANAGER_ROLE) — stored pending until the owner approves it (the approve* / approveSend
 *         functions on {IBittyV1Owner}). Implemented by the core {BittyV1Vault}.
 */
interface IBittyV1PaymentManager {
    event ScheduledPaymentAdded(uint256 indexed id, IBittyV1Vault.ScheduledPayment scheduledPayment);
    event ScheduledPaymentUpdated(uint256 indexed id, IBittyV1Vault.ScheduledPayment scheduledPayment);
    event ScheduledPaymentRemoved(uint256 indexed id);
    event WhitelistedRecipientSet(uint256 indexed id, address recipient, address allowedAsset);
    event WhitelistedRecipientRemoved(uint256 indexed id);
    event SendProposed(
        uint256 indexed id, address indexed proposer, address[] recipients, address[] assets, uint256[] amounts
    );
    event SendCancelled(uint256 indexed id);

    // ============ Scheduled payments ============

    function addScheduledPayment(IBittyV1Vault.ScheduledPayment calldata scheduledPayment) external returns (uint256 id);
    function updateScheduledPayment(uint256 id, IBittyV1Vault.ScheduledPayment calldata scheduledPayment) external;
    function removeScheduledPayment(uint256 id) external;

    // ============ Whitelisted recipients ============

    function addWhitelistedRecipient(address recipient, address allowedAsset) external returns (uint256 id);
    function updateWhitelistedRecipient(uint256 id, address recipient, address allowedAsset) external;
    function removeWhitelistedRecipient(uint256 id) external;

    // ============ One-off sends ============

    /**
     * @notice Owner: execute a batch of transfers immediately. Payment manager: queue the entire batch
     * for owner approval (its id is in the {SendProposed} event). All arrays must be non-empty and
     * have equal lengths.
     */
    function send(address[] calldata recipients, address[] calldata assets, uint256[] calldata amounts) external;

    /**
     * @notice Owner, or the payment manager who proposed it: cancel a pending one-off send.
     */
    function cancelSend(uint256 id) external;
}
