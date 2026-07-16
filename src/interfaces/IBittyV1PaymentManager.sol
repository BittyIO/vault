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
    event ScheduledPaymentAdded(string indexed name, IBittyV1Vault.ScheduledPayment scheduledPayment);
    event ScheduledPaymentUpdated(string indexed name, IBittyV1Vault.ScheduledPayment scheduledPayment);
    event ScheduledPaymentRemoved(string indexed name);
    event WhitelistedRecipientSet(string indexed name, address recipient, address allowedAsset);
    event WhitelistedRecipientRemoved(string indexed name);
    event SendProposed(uint256 indexed id, address indexed proposer, address recipient, address asset, uint256 amount);
    event SendCancelled(uint256 indexed id);

    // ============ Scheduled payments ============

    function addScheduledPayment(string memory name, IBittyV1Vault.ScheduledPayment calldata scheduledPayment) external;
    function updateScheduledPayment(string memory name, IBittyV1Vault.ScheduledPayment calldata scheduledPayment)
        external;
    function removeScheduledPayment(string memory name) external;

    // ============ Whitelisted recipients ============

    function addWhitelistedRecipient(string memory name, address recipient, address allowedAsset) external;
    function updateWhitelistedRecipient(string memory name, address recipient, address allowedAsset) external;
    function removeWhitelistedRecipient(string memory name) external;

    // ============ One-off sends ============

    /**
     * @notice Owner: transfer an asset immediately. Payment manager: queue a pending send that the
     * owner must approve (its id is in the {SendProposed} event).
     */
    function send(address recipient, address asset, uint256 amount) external;

    /**
     * @notice Owner, or the payment manager who proposed it: cancel a pending one-off send.
     */
    function cancelSend(uint256 id) external;
}
