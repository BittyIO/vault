// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "./IBittyV1Vault.sol";

/**
 * @title IBittyV1Owner
 * @notice The owner-only (DEFAULT_ADMIN_ROLE) vault surface: config, asset-manager guardrails,
 *         approval of payment-manager proposals, and the whitelisted-recipient payout. Implemented by
 *         the core {BittyV1Vault}. Payment CREATION (callable by owner or payment manager) lives in
 *         {IBittyV1PaymentManager}; reads/permissionless in {IBittyV1Vault}; the asset-manager
 *         (ASSET_MANAGER_ROLE) functions in {IBittyV1AssetManager}.
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
    event TradeLimitSet(
        address indexed assetManager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt
    );
    event FullAssetManagerAdded(address indexed assetManager);
    event AssetManagerRemoved();
    event ScheduledPaymentProtectionSet(uint256 protectionDuration);
    event WhitelistedProtectionSet(uint256 protectionDuration);
    event MaxSendValueSet(uint256 value);
    event MaxScheduledValueSet(uint256 value);
    event MaxWhitelistedValueSet(uint256 value);
    event ChangeTimelockSet(uint256 value);
    event WhitelistedRecipientPaid(uint256 indexed id, address indexed recipient, address asset, uint256 amount);
    // Owner approval of payment-manager proposals (creation events live on {IBittyV1PaymentManager}).
    event ScheduledPaymentApproved(uint256 indexed id);
    event WhitelistedRecipientApproved(uint256 indexed id);
    event SendApproved(uint256 indexed id, address recipient, address asset, uint256 amount);

    // ============ Vault config ============

    /**
     * @notice Add guard-registered assets/stablecoins to the vault allowlist.
     */
    function addAssets(address[] memory assetAddresses) external;

    /**
     * @notice Remove assets from the vault allowlist.
     */
    function removeAssets(address[] memory assetAddresses) external;

    /**
     * @notice Irreversibly stop new assets from being added (removals still allowed).
     */
    function disableAddingAssets() external;

    /**
     * @notice Irreversibly stop new protocols from being added (removals still allowed).
     */
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

    // ============ Asset-manager guardrails (owner-set) ============

    /**
     * @notice Set the minimum balance that must remain after any sell of `assetAddress` (token
     *         decimals; 0 disables). Bounds what the asset manager can move.
     */
    function setMinimalBalance(address assetAddress, uint256 minimalBalance) external;

    /**
     * @notice Set the vault's single (restricted) asset manager and its trade guardrail, replacing any
     *         previous manager. Only this address may trade, subject to the caps. The owner may set
     *         itself. Reverts if `stableCoinInvestCap == 0`.
     * @param interval Min seconds between trades (0 = no throttle).
     * @param maxStableCoinPerTrade Max stablecoin per trade in whole tokens (0 = no cap).
     * @param stableCoinInvestCap Max whole-token stablecoin the manager may have invested into assets
     *        at once; reverts if 0.
     * @param expiredAt Unix timestamp after which this asset manager may not trade (0 = never).
     */
    function setAssetManager(
        address assetManager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt
    ) external;

    /**
     * @notice Set the vault's single asset manager as full-access — bounded only by minimal balances,
     *         with no invest cap, per-trade cap, throttle, expiry, or stablecoin-leg requirement (so it
     *         can trade any asset, including asset->asset). Replaces any previous manager. For keys as
     *         trusted as the owner; use {setAssetManager} for a delegated key that needs guardrails.
     */
    function setFullAssetManager(address assetManager) external;

    /**
     * @notice Remove the vault's asset manager (leaving the vault with none, so no one can trade).
     */
    function removeAssetManager() external;

    // ============ Sending ============

    /**
     * @notice Owner: execute a payment-manager-proposed one-off send (id from the SendProposed event).
     */
    function approveSend(uint256 id) external;

    // ============ Payment-manager approvals ============

    /**
     * @notice Owner: approve a payment-manager-proposed scheduled payment so it becomes payable.
     */
    function approveScheduledPayment(uint256 id) external;

    /**
     * @notice Owner: approve a payment-manager-proposed whitelisted recipient so it becomes payable.
     */
    function approveWhitelistedRecipient(uint256 id) external;

    /**
     * @notice Set the time-lock window applied to every newly added scheduled-payment address before it
     * can be paid. Lowering it is a loosening (waits the change timelock); raising it is immediate.
     */
    function setScheduledPaymentProtection(uint256 protection) external;

    /**
     * @notice Set the time-lock window applied to every newly added whitelisted recipient before it can
     * be paid. Lowering it is a loosening (waits the change timelock); raising it is immediate.
     */
    function setWhitelistedProtection(uint256 protection) external;

    /**
     * @notice Set a per-path payment cap (stablecoin whole tokens). A non-zero cap makes that path
     *         stablecoin-only and bounds each payment's value; 0 removes the restriction. Applies to
     *         newly created payments; existing ones are grandfathered (except whitelisted, checked at
     *         each payout). Any value is allowed, but a loosening (raising or clearing a cap) only takes
     *         effect after the change timelock; tightening is immediate.
     */
    function setMaxSendValue(uint256 value) external;
    function setMaxScheduledValue(uint256 value) external;
    function setMaxWhitelistedValue(uint256 value) external;

    /**
     * @notice Set the change timelock (seconds) — the delay a loosening of any risk control must wait.
     *         Lowering it is itself a loosening (waits the current timelock); raising it is immediate.
     */
    function setChangeTimelock(uint256 value) external;

    // ============ Whitelisted recipient payout (owner-only) ============

    /**
     * @notice Pay a whitelisted recipient a discretionary amount from the vault's balance.
     */
    function sendToWhitelistedRecipient(uint256 id, address asset, uint256 amount) external;
}
