// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "./IBittyV1Vault.sol";

/**
 * @title IBittyV1Owner
 * @notice Every owner-only (DEFAULT_ADMIN_ROLE) vault function and the events they emit. Implemented
 *         by the core {BittyV1Vault}. Read/permissionless functions live in {IBittyV1Vault}; the
 *         asset-manager (ASSET_MANAGER_ROLE) functions live in {IBittyV1AssetManager}.
 */
interface IBittyV1Owner {
    // ============ Events ============
    event NameSet(string newName);
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
    event TradeLimitSet(address indexed assetManager, uint256 interval, uint256 maxStableCoinSize);
    event ScheduledPaymentAdded(string indexed name, IBittyV1Vault.ScheduledPayment scheduledPayment);
    event ScheduledPaymentUpdated(string indexed name, IBittyV1Vault.ScheduledPayment scheduledPayment);
    event ScheduledPaymentRemoved(string indexed name);
    event NewAddressProtectionSet(uint256 protectionDuration);
    event WhitelistedRecipientSet(string indexed name, address recipient, address allowedAsset);
    event WhitelistedRecipientRemoved(string indexed name);
    event WhitelistedRecipientPaid(string indexed name, address indexed recipient, address asset, uint256 amount);

    // ============ Vault config ============

    /**
     * @notice Set the human-readable vault name.
     */
    function setName(string memory name) external;

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

    // ============ Sending ============

    /**
     * @notice Send an asset from the vault to any recipient (can be disabled via {disableSending}).
     */
    function send(address recipient, address asset, uint256 amount) external;

    /**
     * @notice Irreversibly-until-reenabled disable {send}.
     */
    function disableSending() external;

    // ============ Scheduled payments ============

    function addScheduledPayment(string memory name, IBittyV1Vault.ScheduledPayment calldata scheduledPayment) external;
    function updateScheduledPayment(string memory name, IBittyV1Vault.ScheduledPayment calldata scheduledPayment)
        external;
    function removeScheduledPayment(string memory name) external;

    /**
     * @notice Set the time-lock window applied to every newly added scheduled payment / whitelisted
     * recipient before it can be paid.
     */
    function setNewAddressProtection(uint256 newAddressProtection) external;

    // ============ Whitelisted recipients ============

    function addWhitelistedRecipient(string memory name, address recipient, address allowedAsset) external;
    function updateWhitelistedRecipient(string memory name, address recipient, address allowedAsset) external;
    function removeWhitelistedRecipient(string memory name) external;

    /**
     * @notice Pay a whitelisted recipient a discretionary amount from the vault's balance.
     */
    function sendToWhitelistedRecipient(string memory name, address asset, uint256 amount) external;
}
