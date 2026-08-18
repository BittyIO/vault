// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "./IBittyV1Vault.sol";

/**
 * @title IBittyV1PayoutOperator
 * @notice The payment-creation surface: scheduled payments, whitelisted recipients and one-off sends.
 *         Callable by the owner (DEFAULT_ADMIN_ROLE) — takes effect immediately — or the vault's
 *         payout operator (set via {IBittyV1Owner.updatePayoutOperators}) — stored pending until the owner
 *         approves it (the approve* / reviewSends functions on {IBittyV1Owner}). Implemented by {BittyV1Vault}.
 */
interface IBittyV1PayoutOperator {
    event ScheduledPaymentsAdded(uint256[] ids, IBittyV1Vault.ScheduledPayment[] scheduledPayments);
    event ScheduledPaymentsUpdated(uint256[] ids, IBittyV1Vault.ScheduledPayment[] scheduledPayments);
    event ScheduledPaymentsRemoved(uint256[] ids);
    event WhitelistedRecipientsSet(uint256[] ids, address[] recipients, address[] allowedAssets);
    event WhitelistedRecipientsRemoved(uint256[] ids);
    event SendProposed(
        uint256 indexed id, address indexed proposer, address[] recipients, address[] assets, uint256[] amounts
    );
    event SendsCancelled(uint256[] ids);

    /**
     * @notice Add one or more scheduled payments in a single call; returns the new ids in order.
     */
    function addScheduledPayments(IBittyV1Vault.ScheduledPayment[] calldata scheduledPayments)
        external
        returns (uint256[] memory ids);

    /**
     * @notice Update scheduled payments in a single call. ids[i] is set to scheduledPayments[i]; arrays must
     *         be equal length.
     */
    function updateScheduledPayments(
        uint256[] calldata ids,
        IBittyV1Vault.ScheduledPayment[] calldata scheduledPayments
    ) external;

    /**
     * @notice Remove one or more scheduled payments by id in a single call.
     */
    function removeScheduledPayments(uint256[] calldata ids) external;

    /**
     * @notice Add one or more whitelisted recipients in a single call; returns the new ids in order. arrays
     *         must be equal length.
     */
    function addWhitelistedRecipients(address[] calldata recipients, address[] calldata allowedAssets)
        external
        returns (uint256[] memory ids);

    /**
     * @notice Update whitelisted recipients in a single call. ids[i] is set to (recipients[i],
     *         allowedAssets[i]); arrays must be equal length.
     */
    function updateWhitelistedRecipients(
        uint256[] calldata ids,
        address[] calldata recipients,
        address[] calldata allowedAssets
    ) external;

    /**
     * @notice Remove one or more whitelisted recipients by id in a single call.
     */
    function removeWhitelistedRecipients(uint256[] calldata ids) external;

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
     * @notice Owner, or the payout operator who proposed them: cancel pending one-off sends by id.
     */
    function cancelSends(uint256[] calldata ids) external;
}
