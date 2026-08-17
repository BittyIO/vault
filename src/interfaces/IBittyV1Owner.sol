// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault, AutoYield} from "./IBittyV1Vault.sol";

/**
 * @title IBittyV1Owner
 * @notice The owner-only (DEFAULT_ADMIN_ROLE) vault surface: config, asset manager guardrails, payout operator
 *         guardrails, approval of payout operator proposals, and the whitelisted-recipient payout. Implemented
 *         by {BittyV1Vault}. Payment creation (callable by owner or payout operator) lives in
 *         {IBittyV1PayoutOperator}; reads/permissionless in {IBittyV1Vault}; asset manager trading/yield in
 *         {IBittyV1AssetManager}.
 */
interface IBittyV1Owner {
    /**
     * @notice Input to {updatePaymentRisk}: the payment-risk controls. Set a field to
     *         type(uint256).max ("UNCHANGED") to leave it as-is — those fields cost no storage access.
     *         Any other value is applied through the loosen-waits-changeTimelock guard.
     */
    struct PaymentRisk {
        uint256 newPaymentProtection;
        uint256 maxSendValue;
        uint256 maxSendInterval;
        uint256 changeTimelock;
    }

    // ============ Events ============
    event AssetsUpdated(address[] addAssets, address[] removeAssets);
    event AssetsLocked();
    event ProtocolsLocked();
    event LendingProtocolsUpdated(address[] addLendingProtocols, address[] removeLendingProtocols);
    event StakingProtocolsUpdated(address[] addStakingProtocols, address[] removeStakingProtocols);
    event AMMProtocolsUpdated(address[] addAMMProtocols, address[] removeAMMProtocols);
    event IntentProtocolsUpdated(address[] addIntentProtocols, address[] removeIntentProtocols);
    event MinimalBalancesSet(address[] assets, uint256[] minimalBalances);
    event AutoYieldTriggerSet(address indexed trigger);
    event AssetManagerSet(address indexed assetManager);
    // Ownership renounced: pending payouts cleared and the admin role instantly
    // dropped, leaving the vault ownerless. This is the ONLY renounce path
    // (there is no delayed default-admin transfer).
    event OwnershipRenounced(address indexed formerOwner);
    event PayoutOperatorsUpdated(address[] addPayoutOperators, address[] removePayoutOperators);
    // One event for a whole {updatePaymentRisk} call; echoes the input (UNCHANGED fields carry the sentinel).
    event PaymentRiskUpdated(PaymentRisk paymentRisk);
    // Batched: one event per batch call. No indexed fields; consumers decode the arrays.
    event WhitelistedRecipientsPaid(uint256[] ids, address[] recipients, address[] assets, uint256[] amounts);
    // Owner review of payout operator proposals (creation events live on {IBittyV1PayoutOperator}).
    event ScheduledPaymentsApproved(uint256[] ids);
    event WhitelistedRecipientsApproved(uint256[] ids);
    // Approved send ids only; recipients/assets/amounts are recoverable from the matching {SendProposed}.
    event SendsApproved(uint256[] ids);

    // ============ Vault config ============
    function updateAssets(address[] memory addAssets, address[] memory removeAssets) external;
    function disableAddingAssets() external;
    function disableAddingProtocols() external;

    /**
     * @notice The single renounce path. Instantly drops the admin role after
     *         verifying the caller's pre-committed rescue, leaving the vault
     *         permanently ownerless. No transfer delay, no cancel window. It
     *         clears nothing and loops over nothing, so an attacker holding the
     *         same key cannot grief it by inflating the scheduled-payment count.
     *         After renounce, payScheduled pays ONLY locked immutable payments,
     *         so every other entry (an attacker's injected mutable payment, or a
     *         whitelisted recipient — inert anyway, since sendToWhitelistedRecipient
     *         is owner-only) can never move funds.
     *
     * @param rescueScheduledPaymentId A locked immutable scheduled payment
     *        (immutable, approved, past its lock deadline, payments remaining) —
     *        the owner's pre-committed rescue that keeps paying its safe address
     *        in the ownerless vault. Reverts NoRescueTarget if it isn't one, so
     *        funds are never stranded.
     *
     *        It is passed in — rather than discovered on-chain — because the
     *        contract cannot cheaply find one itself, and this is the crux of the
     *        DoS-resistance:
     *        - Searching all payments for a locked immutable one is O(n) over an
     *          ever-growing id space (nextScheduledPaymentId only increments, even
     *          as entries are removed). That search is exactly the gas-griefing
     *          vector this design avoids: an attacker could add thousands of
     *          payments so the scan exceeds the block gas limit and bricks the
     *          renounce.
     *        - A cached counter can't replace the search either, because "locked"
     *          depends on block.timestamp >= effectiveAt, and crossing that
     *          deadline happens with the passage of time, not via any transaction —
     *          there is no moment at which to maintain the count. Counting merely
     *          immutable (not-yet-effective) payments would be unsafe: an
     *          attacker's immutable payment still inside its lock window would pass
     *          the check, then mature and drain to the attacker after renounce.
     *        So the owner names one witness and the contract verifies it in O(1).
     *
     *        It is only PROOF that a valid rescue exists — NOT a selector. After
     *        renounce, payScheduled pays EVERY locked immutable payment, not just
     *        this one, so a single id is sufficient regardless of how many the
     *        owner set up.
     */
    function renounceVaultOwnership(uint256 rescueScheduledPaymentId) external;

    /**
     * @notice Batch-set the lending protocols. Adds are applied before removes.
     */
    function updateLendingProtocols(address[] memory addLendingProtocols, address[] memory removeLendingProtocols)
        external;

    /**
     * @notice Batch-set the staking protocols. Adds are applied before removes.
     */
    function updateStakingProtocols(address[] memory addStakingProtocols, address[] memory removeStakingProtocols)
        external;

    /**
     * @notice Batch-set the AMM protocols. Adds are applied before removes.
     */
    function updateAMMProtocols(address[] memory addAMMProtocols, address[] memory removeAMMProtocols) external;

    /**
     * @notice Batch-set the intent protocols. Adds are applied before removes.
     */
    function updateIntentProtocols(address[] memory addIntentProtocols, address[] memory removeIntentProtocols) external;

    /**
     * @notice Batch-set the per-asset minimal balance (the liquid buffer kept out of
     *         auto-yield). One call for many assets; arrays must be equal length.
     */
    function setMinimalBalances(address[] calldata assetAddresses, uint256[] calldata minimalBalances) external;

    /**
     * @notice Batch-set the per-asset default yield route. One call for many assets; protocol = address(0) in a route clears that asset's route.
     */
    function setAutoYieldings(AutoYield[] calldata routes) external;

    /**
     * @notice Set (or clear, trigger = address(0)) the address allowed to call {IBittyV1Vault.autoYield}
     *         on demand, on top of the vault's own deposit-time trigger. Use a trusted keeper — the call
     *         moves funds into a yield position, so it must never be permissionless.
     */
    function setAutoYieldTrigger(address trigger) external;

    /**
     * @notice Set the vault's single asset manager, replacing any previous one. Only this address may trade;
     *         it has full trading access, bounded only by the token allowlist and per-asset minimal-balance
     *         floors. The owner may set itself.
     */
    function setAssetManager(address assetManager) external;

    /**
     * @notice Add and/or remove payout operators in one call (like {updateLendingProtocols}). Each added
     *         address must not already be registered and may not be the owner; each removed address must be
     *         registered. Adds are applied before removes.
     */
    function updatePayoutOperators(address[] calldata addPayoutOperators, address[] calldata removePayoutOperators)
        external;

    /**
     * @notice Owner: approve and/or cancel pending payout operator send proposals in one call (like
     *         {updatePayoutOperators}). approveIds are executed immediately; cancelIds are dropped. Approves
     *         are applied before cancels.
     */
    function reviewSends(uint256[] calldata approveIds, uint256[] calldata cancelIds) external;

    /**
     * @notice Owner: approve and/or reject payout operator scheduled-payment proposals in one call (like
     *         {reviewSends}). approveIds are approved — each expectedHashes[i] is
     *         keccak256(abi.encode(the ScheduledPayment the owner reviewed)) for approveIds[i], and a
     *         mismatch reverts so a proposer cannot swap content before approval — while cancelIds are
     *         removed. Approves run before cancels; approveIds/expectedHashes must be equal length.
     */
    function reviewScheduledPayments(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external;

    /**
     * @notice Owner: approve and/or reject payout operator whitelisted-recipient proposals in one call (like
     *         {reviewSends}). approveIds are approved — each expectedHashes[i] is
     *         keccak256(abi.encode(the WhitelistedRecipient the owner reviewed)) for approveIds[i], and a
     *         mismatch reverts so a proposer cannot swap content before approval — while cancelIds are
     *         removed. Approves run before cancels; approveIds/expectedHashes must be equal length.
     */
    function reviewWhitelistedRecipients(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external;

    /**
     * @notice Update any subset of the payment-risk controls in one call. Fields set to the UNCHANGED
     *         sentinel (type(uint256).max) are left untouched (no storage access); the rest are applied
     *         through the loosen-waits-changeTimelock guard. Cheaper than separate setters when changing two
     *         or more, and never a blind copy — an in-flight (pending) timelocked change on an untouched
     *         field is preserved.
     */
    function updatePaymentRisk(PaymentRisk calldata update) external;

    /**
     * @notice Owner: pay one or more whitelisted recipients in a single call. ids/assets/amounts must be
     *         non-empty and equal length; row `i` pays `amounts[i]` of `assets[i]` to whitelisted recipient
     *         `ids[i]`.
     * @dev May first source the funds from yield positions: for row `i`, `stakingAmounts[i]` of `assets[i]`
     *      is unstaked from `stakingProtocols[i]` and `lendingAmounts[i]` withdrawn from `lendingProtocols[i]`
     *      into the vault before paying (`address(0)` / `0` = skip that leg). When any position array is
     *      non-empty all four must equal `assets.length`; pass empty arrays for a plain vault-balance payout.
     */
    function sendToWhitelistedRecipients(
        uint256[] calldata ids,
        address[] calldata assets,
        uint256[] calldata amounts,
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) external;
}
