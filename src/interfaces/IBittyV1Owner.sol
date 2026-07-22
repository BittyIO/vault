// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "./IBittyV1Vault.sol";

/**
 * @title IBittyV1Owner
 * @notice The owner-only (DEFAULT_ADMIN_ROLE) vault surface: config, manager guardrails, operator
 *         guardrails, approval of operator proposals, and the whitelisted-recipient payout. Implemented
 *         by {BittyV1Vault}. Payment creation (callable by owner or operator) lives in
 *         {IBittyV1Operator}; reads/permissionless in {IBittyV1Vault}; manager trading/yield in
 *         {IBittyV1Manager}.
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
        address indexed manager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt
    );
    event FullManagerAdded(address indexed manager);
    event ManagerRemoved();
    event OperatorSendLimitSet(address indexed operator, uint256 interval, uint256 maxStableCoinPerPeriod);
    event OperatorRemoved(address indexed operator);
    event ScheduledPaymentProtectionSet(uint256 protectionDuration);
    event WhitelistedProtectionSet(uint256 protectionDuration);
    event MaxSendValueSet(uint256 value);
    event MaxScheduledValueSet(uint256 value);
    event MaxWhitelistedValueSet(uint256 value);
    event ChangeTimelockSet(uint256 value);
    event WhitelistedRecipientPaid(uint256 indexed id, address indexed recipient, address asset, uint256 amount);
    // Owner approval of operator proposals (creation events live on {IBittyV1Operator}).
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

    // ============ Manager guardrails (owner-set) ============

    function setMinimalBalance(address assetAddress, uint256 minimalBalance) external;

    /**
     * @notice Set the vault's single (restricted) manager and its trade guardrail, replacing any previous
     *         manager. Only this address may trade, subject to the caps. The owner may set itself. Reverts
     *         if `stableCoinInvestCap == 0`.
     */
    function setManager(
        address manager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt
    ) external;

    /**
     * @notice Set the vault's single manager as full-access — bounded only by minimal balances, with no
     *         invest cap, per-trade cap, throttle, expiry, or stablecoin-leg requirement. Replaces any
     *         previous manager. For keys as trusted as the owner; use {setManager} for a delegated key.
     */
    function setFullManager(address manager) external;

    function removeManager() external;

    // ============ Operator guardrails (owner-set) ============

    /**
     * @notice Register a new operator and its rolling one-off send quota. Does not remove other operators.
     *         The owner may not be an operator. Reverts if already registered or if
     *         `maxStableCoinPerPeriod == 0`.
     */
    function setOperator(address operator, uint256 interval, uint256 maxStableCoinPerPeriod) external;

    /**
     * @notice Update an existing operator's rolling one-off send quota. Preserves the current period
     *         usage. Reverts if not registered or if `maxStableCoinPerPeriod == 0`.
     */
    function updateOperator(address operator, uint256 interval, uint256 maxStableCoinPerPeriod) external;

    function removeOperator(address operator) external;

    // ============ Sending ============

    function approveSend(uint256 id) external;

    // ============ Operator approvals ============

    function approveScheduledPayment(uint256 id) external;
    function approveWhitelistedRecipient(uint256 id) external;

    function setScheduledPaymentProtection(uint256 protection) external;
    function setWhitelistedProtection(uint256 protection) external;
    function setMaxSendValue(uint256 value) external;
    function setMaxScheduledValue(uint256 value) external;
    function setMaxWhitelistedValue(uint256 value) external;
    function setChangeTimelock(uint256 value) external;

    function sendToWhitelistedRecipient(uint256 id, address asset, uint256 amount) external;
}
