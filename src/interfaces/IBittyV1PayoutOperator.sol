// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "./IBittyV1Vault.sol";

/**
 * @title IBittyV1PayoutOperator
 * @notice The payment-creation surface: scheduled payments, whitelisted recipients and one-off sends.
 *         Callable by the owner (DEFAULT_ADMIN_ROLE) — takes effect immediately — or the vault's
 *         payout operator (set via {IBittyV1Owner.addPayoutOperator}) — stored pending until the owner approves it
 *         (the approve* / approveSend functions on {IBittyV1Owner}). Implemented by {BittyV1Vault}.
 */
interface IBittyV1PayoutOperator {
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
     * @notice Owner: execute a batch of transfers immediately. Payout operator: queue the entire batch for
     *         owner approval (its id is in the {SendProposed} event). recipients/assets/amounts must be
     *         non-empty and equal length.
     * @dev Owner-direct sends may also source funds from yield positions before paying: for row `i`,
     *      `stakingAmounts[i]` of `assets[i]` is unstaked from `stakingProtocols[i]` and `lendingAmounts[i]`
     *      withdrawn from `lendingProtocols[i]` into the vault first (`address(0)` / `0` = skip that leg).
     *      When any position array is non-empty all four must equal `assets.length`; pass empty arrays for a
     *      plain vault-balance send. Position sourcing is ignored on the payout-operator propose path.
     */
    function send(
        address[] calldata recipients,
        address[] calldata assets,
        uint256[] calldata amounts,
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) external;

    /**
     * @notice Owner, or the payout operator who proposed it: cancel a pending one-off send.
     */
    function cancelSend(uint256 id) external;
}
