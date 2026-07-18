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
    event OwnerAssetManagerDisabled();
    event LendingProtocolsAdded(address[] protocols);
    event LendingProtocolsRemoved(address[] protocols);
    event StakingProtocolsAdded(address[] protocols);
    event StakingProtocolsRemoved(address[] protocols);
    event AMMProtocolsAdded(address[] protocols);
    event AMMProtocolsRemoved(address[] protocols);
    event IntentProtocolsAdded(address[] protocols);
    event IntentProtocolsRemoved(address[] protocols);
    event MinimalBalanceSet(address indexed asset, uint256 minimalBalance);
    event TradeLimitSet(address indexed assetManager, uint256 interval, uint256 maxStableCoinSize);
    event NewAddressProtectionSet(uint256 protectionDuration);
    event WhitelistedRecipientPaid(string indexed name, address indexed recipient, address asset, uint256 amount);
    // Owner approval of payment-manager proposals (creation events live on {IBittyV1PaymentManager}).
    event ScheduledPaymentApproved(string indexed name);
    event WhitelistedRecipientApproved(string indexed name);
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
     * @notice Set a per-asset-manager trade guardrail: min seconds between trades and a per-trade
     *         stablecoin size cap (whole tokens). See implementation for the stablecoin-leg rule.
     */
    function setTradeLimit(address assetManager, uint256 interval, uint256 maxStableCoinSize) external;

    /**
     * @notice Drop the owner's implicit asset-manager capability (one-way). By default the owner may
     *         trade without holding ASSET_MANAGER_ROLE, so a single-wallet user needs no second key;
     *         calling this restricts trading to explicit ASSET_MANAGER_ROLE holders only.
     */
    function disableOwnerAssetManager() external;

    // ============ Sending ============

    /**
     * @notice Irreversibly-until-reenabled disable {IBittyV1PaymentManager.send}.
     */
    function disableSending() external;

    /**
     * @notice Owner: execute a payment-manager-proposed one-off send (id from the SendProposed event).
     */
    function approveSend(uint256 id) external;

    // ============ Payment-manager approvals ============

    /**
     * @notice Owner: approve a payment-manager-proposed scheduled payment so it becomes payable.
     */
    function approveScheduledPayment(string memory name) external;

    /**
     * @notice Owner: approve a payment-manager-proposed whitelisted recipient so it becomes payable.
     */
    function approveWhitelistedRecipient(string memory name) external;

    /**
     * @notice Set the time-lock window applied to every newly added scheduled payment / whitelisted
     * recipient before it can be paid.
     */
    function setNewAddressProtection(uint256 newAddressProtection) external;

    // ============ Whitelisted recipient payout (owner-only) ============

    /**
     * @notice Pay a whitelisted recipient a discretionary amount from the vault's balance.
     */
    function sendToWhitelistedRecipient(string memory name, address asset, uint256 amount) external;
}
