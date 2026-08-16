// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "./IBittyV1Vault.sol";

/**
 * @title IBittyV1Owner
 * @notice The owner-only (DEFAULT_ADMIN_ROLE) vault surface: config, asset manager guardrails, payout operator
 *         guardrails, approval of payout operator proposals, and the whitelisted-recipient payout. Implemented
 *         by {BittyV1Vault}. Payment creation (callable by owner or payout operator) lives in
 *         {IBittyV1PayoutOperator}; reads/permissionless in {IBittyV1Vault}; asset manager trading/yield in
 *         {IBittyV1AssetManager}.
 */
interface IBittyV1Owner {
    // ============ Events ============
    event AssetsUpdated(address[] addAssets, address[] removeAssets);
    event AssetsLocked();
    event ProtocolsLocked();
    event LendingProtocolsUpdated(address[] addLendingProtocols, address[] removeLendingProtocols);
    event StakingProtocolsUpdated(address[] addStakingProtocols, address[] removeStakingProtocols);
    event AMMProtocolsUpdated(address[] addAMMProtocols, address[] removeAMMProtocols);
    event IntentProtocolsUpdated(address[] addIntentProtocols, address[] removeIntentProtocols);
    event MinimalBalanceSet(address indexed asset, uint256 minimalBalance);
    event AutoYieldTriggerSet(address indexed trigger);
    event AssetManagerSet(address indexed assetManager);
    // Ownership renounced: pending payouts cleared and the admin role instantly
    // dropped, leaving the vault ownerless. This is the ONLY renounce path
    // (there is no delayed default-admin transfer).
    event OwnershipRenounced(address indexed formerOwner);
    event AssetManagerRemoved();
    event PayoutOperatorAdded(address indexed payoutOperator);
    event PayoutOperatorRemoved(address indexed payoutOperator);
    event ScheduledPaymentProtectionSet(uint256 protectionDuration);
    event WhitelistedProtectionSet(uint256 protectionDuration);
    event MaxSendValueSet(uint256 value);
    event MaxSendIntervalSet(uint256 value);
    event MaxScheduledValueSet(uint256 value);
    event MaxWhitelistedValueSet(uint256 value);
    event ChangeTimelockSet(uint256 value);
    event WhitelistedRecipientPaid(uint256 indexed id, address indexed recipient, address asset, uint256 amount);
    // Owner approval of payout operator proposals (creation events live on {IBittyV1PayoutOperator}).
    event ScheduledPaymentApproved(uint256 indexed id);
    event WhitelistedRecipientApproved(uint256 indexed id);
    event SendApproved(uint256 indexed id, address[] recipients, address[] assets, uint256[] amounts);

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

    // ============ Protocol management ============
    function updateLendingProtocols(address[] memory addLendingProtocols, address[] memory removeLendingProtocols)
        external;
    function updateStakingProtocols(address[] memory addStakingProtocols, address[] memory removeStakingProtocols)
        external;
    function updateAMMProtocols(address[] memory addAMMProtocols, address[] memory removeAMMProtocols) external;
    function updateIntentProtocols(address[] memory addIntentProtocols, address[] memory removeIntentProtocols) external;

    
    function setMinimalBalance(address assetAddress, uint256 minimalBalance) external;

    /**
     * @notice Set (or clear, protocol = address(0)) the asset's default yield route. Once set, the
     *         vault auto-routes spendable balance of `assetAddress` into `protocol` on deposit — the
     *         vault's {receive} sweeps freshly-wrapped ETH into the WETH route, so ETH deposits earn
     *         by default. Routing is never a standalone entry point (that would let a griefer strand
     *         the asset manager's swap liquidity). `isSupplying` picks the kind: true = lending supply,
     *         false = staking stake; the protocol must already be registered on the vault for that
     *         kind. The asset's minimalBalance is kept liquid (never auto-yielded), as are tokens
     *         reserved by open intent orders.
     */
    function setAutoYielding(address assetAddress, address protocol, bool isSupplying) external;

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

    function removeAssetManager() external;

    // ============ Payout operators (owner-set) ============

    /**
     * @notice Register a new payout operator. Does not remove other payout operators. The owner may not be
     *         a payout operator. Reverts if already registered.
     */
    function addPayoutOperator(address payoutOperator) external;

    function removePayoutOperator(address payoutOperator) external;

    // ============ Sending ============

    function approveSend(uint256 id) external;

    // ============ Payout operator approvals ============

    /**
     * @param expectedHash keccak256(abi.encode(the ScheduledPayment the owner reviewed)); the call
     * reverts if the stored entry no longer matches, so a proposer cannot swap content before approval.
     */
    function approveScheduledPayment(uint256 id, bytes32 expectedHash) external;
    /**
     * @param expectedHash keccak256(abi.encode(the WhitelistedRecipient the owner reviewed)); the call
     * reverts if the stored entry no longer matches, so a proposer cannot swap content before approval.
     */
    function approveWhitelistedRecipient(uint256 id, bytes32 expectedHash) external;

    function setScheduledPaymentProtection(uint256 protection) external;
    function setWhitelistedProtection(uint256 protection) external;
    function setMaxSendValue(uint256 value) external;
    function setMaxSendInterval(uint256 value) external;
    function setMaxScheduledValue(uint256 value) external;
    function setMaxWhitelistedValue(uint256 value) external;
    function setChangeTimelock(uint256 value) external;

    /**
     * @notice Owner: pay a whitelisted recipient. May first source the funds from yield positions —
     *         `stakingAmount` of `asset` is unstaked from `stakingProtocol` and `lendingAmount` withdrawn
     *         from `lendingProtocol` into the vault before paying (`address(0)` / `0` = skip that leg).
     */
    function sendToWhitelistedRecipient(
        uint256 id,
        address asset,
        uint256 amount,
        address stakingProtocol,
        uint256 stakingAmount,
        address lendingProtocol,
        uint256 lendingAmount
    ) external;
}
