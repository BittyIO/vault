// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {AutoYield} from "./IBittyV1Vault.sol";

/**
 * @title IBittyV1Owner
 * @notice The owner-only vault surface: config, sub account and payout operator guardrails, approval of
 *         payout operator proposals, and the whitelisted-recipient payout. Implemented by
 *         {BittyV1Vault}. Payment creation (callable by owner or payout operator) lives in
 *         {IBittyV1PayoutOperator}; reads/permissionless in {IBittyV1Vault}; trading/yield in
 *         {IBittyV1DeFi}.
 */
interface IBittyV1Owner {
    struct PaymentRisk {
        uint256 newPaymentProtection;
        uint256 maxSendValue;
        uint256 maxSendInterval;
        uint256 changeTimelock;
    }

    event AssetsUpdated(address[] addAssets, address[] removeAssets);
    event AssetsLocked();
    event ProtocolsLocked();
    event ProtocolsUpdated(address[] addProtocols, address[] removeProtocols);
    event OwnershipRenounced(address indexed formerOwner);
    event PayoutOperatorUpdated(address indexed payoutOperator, bool added);
    event PaymentRiskUpdated(PaymentRisk paymentRisk);
    event WhitelistedRecipientPaid(uint256 indexed id, address recipient, address asset, uint256 amount);
    event ScheduledPaymentsApproved(uint256[] ids);
    event WhitelistedRecipientsApproved(uint256[] ids);
    event SendsApproved(uint256[] ids);
    event SendApproved(uint256 indexed id);
    event Retrieved721(address indexed contractAddress, uint256 indexed tokenId, address indexed to);
    event GaslessSet(bool enabled, address[] assets, uint64 dailyLimit, uint64 maxFeePerOp);
    event ActivationFeePaid(address indexed asset, uint256 amount);
    event RelayerFeePaid(address indexed asset, uint256 amount, uint256 spentToday, uint256 remainingToday);

    /**
     * @notice Update the assets.
     * @param addAssets The assets to add.
     * @param removeAssets The assets to remove.
     */
    function updateAssets(address[] memory addAssets, address[] memory removeAssets) external;

    /**
     * @notice Renounce the vault ownership.
     * @param rescueScheduledPaymentId The ID of the scheduled payment to rescue.
     */
    function renounceVaultOwnership(uint256 rescueScheduledPaymentId) external;

    /**
     * @notice Update the protocols.
     * @param addProtocols The protocols to add.
     * @param removeProtocols The protocols to remove.
     */
    function updateProtocols(address[] memory addProtocols, address[] memory removeProtocols) external;

    /**
     * @notice Set the gasless settings.
     * @param assets The assets to use for gasless operations.
     * @param dailyLimit The daily limit for gasless operations.
     * @param maxFeePerOp The maximum fee per operation for gasless operations.
     */
    function setGasless(address[] calldata assets, uint64 dailyLimit, uint64 maxFeePerOp) external;

    /**
     * @notice Disable gasless operations.
     */
    function disableGasless() external;

    /**
     * @notice Set the auto yieldings.
     * @param routes The auto yieldings to set.
     */
    function setAutoYieldings(AutoYield[] calldata routes) external;

    /**
     * @notice Update the payout operator.
     * @param payoutOperator The address of the payout operator.
     * @param add Whether to add or remove the payout operator.
     */
    function updatePayoutOperator(address payoutOperator, bool add) external;

    /**
     * @notice Owner: approve and/or cancel queued one-off sends proposed by a payout operator.
     *         approveIds are executed immediately; cancelIds are dropped.
     */
    function reviewSends(uint256[] calldata approveIds, uint256[] calldata cancelIds) external;

    /**
     * @notice Approve and/or reject scheduled payment proposals.
     * @param approveIds The IDs of the scheduled payments to approve.
     * @param expectedHashes The hashes of the scheduled payments to approve.
     * @param cancelIds The IDs of the scheduled payments to cancel.
     */
    function reviewScheduledPayments(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external;

    /**
     * @notice Approve and/or reject whitelisted recipient proposals.
     * @param approveIds The IDs of the whitelisted recipients to approve.
     * @param expectedHashes The hashes of the whitelisted recipients to approve.
     * @param cancelIds The IDs of the whitelisted recipients to cancel.
     */
    function reviewWhitelistedRecipients(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external;

    /**
     * @notice paymentRisk the payment risk.
     * @param paymentRisk The payment risk to update.
     */
    function updatePaymentRisk(PaymentRisk calldata paymentRisk) external;

    /**
     * @notice Retrieve an ERC-721 token from the vault.
     * @param contractAddress The address of the ERC-721 contract.
     * @param tokenId The token ID to retrieve.
     * @param to The address to send the token to.
     */
    function retrieve721(address contractAddress, uint256 tokenId, address to) external;

    /**
     * @notice Send to a whitelisted recipient.
     * @param id The id of the whitelisted recipient.
     * @param asset The asset to send.
     * @param amount The amount to send.
     * @param withdrawProtocols The withdrawable protocols to use.
     * @param withdrawAmounts The amounts to withdraw from the withdrawable protocols.
     */
    function sendToWhitelistedRecipient(
        uint256 id,
        address asset,
        uint256 amount,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) external;

    /**
     * @notice Approve a send.
     * @param id The id of the send.
     */
    function approveSend(uint256 id) external;

    /**
     * @notice Set the auto yielding for an asset.
     * @param route The auto yielding route.
     */
    function setAutoYielding(AutoYield calldata route) external;
}
