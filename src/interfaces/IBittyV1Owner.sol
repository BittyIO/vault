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
    event AssetsAdded(address[] assets);
    event AssetsRemoved(address[] assets);
    event AssetsLocked();
    event ProtocolsLocked();
    event LendingProtocolsAdded(address[] protocols);
    event LendingProtocolsRemoved(address[] protocols);
    event StakingProtocolsAdded(address[] protocols);
    event StakingProtocolsRemoved(address[] protocols);
    event AMMProtocolsAdded(address[] protocols);
    event AMMProtocolsRemoved(address[] protocols);
    event IntentProtocolsAdded(address[] protocols);
    event IntentProtocolsRemoved(address[] protocols);
    event MinimalBalanceSet(address indexed asset, uint256 minimalBalance);
    event AutoYieldTriggerSet(address indexed trigger);
    event TradeLimitSet(
        address indexed assetManager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt
    );
    event FullAssetManagerAdded(address indexed assetManager);
    event AssetManagerRemoved();
    event PayoutOperatorSendLimitSet(address indexed payoutOperator, uint256 interval, uint256 maxStableCoinPerPeriod);
    event PayoutOperatorRemoved(address indexed payoutOperator);
    event ScheduledPaymentProtectionSet(uint256 protectionDuration);
    event WhitelistedProtectionSet(uint256 protectionDuration);
    event MaxSendValueSet(uint256 value);
    event MaxScheduledValueSet(uint256 value);
    event MaxWhitelistedValueSet(uint256 value);
    event ChangeTimelockSet(uint256 value);
    event WhitelistedRecipientPaid(uint256 indexed id, address indexed recipient, address asset, uint256 amount);
    // Owner approval of payout operator proposals (creation events live on {IBittyV1PayoutOperator}).
    event ScheduledPaymentApproved(uint256 indexed id);
    event WhitelistedRecipientApproved(uint256 indexed id);
    event SendApproved(uint256 indexed id, address[] recipients, address[] assets, uint256[] amounts);

    // ============ Vault config ============

    function addAssets(address[] memory assetAddresses) external;
    function removeAssets(address[] memory assetAddresses) external;
    function disableAddingAssets() external;
    function disableAddingProtocols() external;

    // ============ Protocol management ============

    function addLendingProtocols(address[] memory lendingProtocolAddresses) external;
    function removeLendingProtocols(address[] memory lendingProtocolAddresses) external;
    function addStakingProtocols(address[] memory stakingProtocolAddresses) external;
    function removeStakingProtocols(address[] memory stakingProtocolAddresses) external;
    function addAMMProtocols(address[] memory ammProtocolAddresses) external;
    function removeAMMProtocols(address[] memory ammProtocolAddresses) external;
    function addIntentProtocols(address[] memory intentProtocolAddresses) external;
    function removeIntentProtocols(address[] memory intentProtocolAddresses) external;

    // ============ Asset manager guardrails (owner-set) ============

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
     * @notice Set the vault's single (restricted) asset manager and its trade guardrail, replacing any previous
     *         asset manager. Only this address may trade, subject to the caps. The owner may set itself. Reverts
     *         if `stableCoinInvestCap == 0`.
     */
    function setAssetManager(
        address assetManager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt
    ) external;

    /**
     * @notice Set the vault's single asset manager as full-access — bounded only by minimal balances, with no
     *         invest cap, per-trade cap, throttle, expiry, or stablecoin-leg requirement. Replaces any
     *         previous asset manager. For keys as trusted as the owner; use {setAssetManager} for a delegated key.
     */
    function setFullAssetManager(address assetManager) external;

    function removeAssetManager() external;

    // ============ Payout operator guardrails (owner-set) ============

    /**
     * @notice Register a new payout operator and its rolling one-off send quota. Does not remove other payout operators.
     *         The owner may not be an payout operator. Reverts if already registered or if
     *         `maxStableCoinPerPeriod == 0`.
     */
    function setPayoutOperator(address payoutOperator, uint256 interval, uint256 maxStableCoinPerPeriod) external;

    /**
     * @notice Update an existing payout operator's rolling one-off send quota. Preserves the current period
     *         usage. Reverts if not registered or if `maxStableCoinPerPeriod == 0`.
     */
    function updatePayoutOperator(address payoutOperator, uint256 interval, uint256 maxStableCoinPerPeriod) external;

    function removePayoutOperator(address payoutOperator) external;

    // ============ Sending ============

    function approveSend(uint256 id) external;

    // ============ Payout operator approvals ============

    /// @param expectedHash keccak256(abi.encode(the ScheduledPayment the owner reviewed)); the call
    /// reverts if the stored entry no longer matches, so a proposer cannot swap content before approval.
    function approveScheduledPayment(uint256 id, bytes32 expectedHash) external;
    /// @param expectedHash keccak256(abi.encode(the WhitelistedRecipient the owner reviewed)); the call
    /// reverts if the stored entry no longer matches, so a proposer cannot swap content before approval.
    function approveWhitelistedRecipient(uint256 id, bytes32 expectedHash) external;

    function setScheduledPaymentProtection(uint256 protection) external;
    function setWhitelistedProtection(uint256 protection) external;
    function setMaxSendValue(uint256 value) external;
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
