// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {WETH} from "solmate/tokens/WETH.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {BittyV1VaultBase} from "./BittyV1VaultBase.sol";
import {IBittyV1Owner} from "./interfaces/IBittyV1Owner.sol";
import {IBittyV1PaymentManager} from "./interfaces/IBittyV1PaymentManager.sol";
import {IBittyV1Vault, AddressZero, OwnerAndManagerMustDiffer} from "./interfaces/IBittyV1Vault.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";

/**
 * @title BittyV1Vault
 * @notice The core custody + payments contract: asset allowlist, scheduled payments and whitelisted
 *         recipients. Asset-management (trading, yield, protocols) lives in
 *         {BittyV1VaultDeFiFacet}, reached through this contract's fallback.
 * @dev
 * Best practices:
 * - DEFAULT_ADMIN_ROLE: hardware wallet / multi-sig. Owns all config and irreversible ops.
 *   Managed via {AccessControlDefaultAdminRulesUpgradeable} (2-step transfer + delay).
 * - ASSET_MANAGER_ROLE: hot wallet / AI agent. Executes yield and trading operations only.
 */
contract BittyV1Vault is BittyV1VaultBase, IBittyV1Owner, IBittyV1PaymentManager {
    using AssetManagerLogic for AssetManagerStorage;

    using VaultLogic for VaultStorage;

    // Payment creation (scheduled payments, whitelisted recipients, one-off sends) is callable by the
    // owner or a payment manager. Owner actions take effect immediately; payment-manager actions are
    // stored pending until the owner approves them.
    modifier onlyOwnerOrPaymentManager() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) && !hasRole(PAYMENT_MANAGER_ROLE, _msgSender())) {
            revert IAccessControl.AccessControlUnauthorizedAccount(_msgSender(), PAYMENT_MANAGER_ROLE);
        }
        _;
    }

    function _byOwner() private view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /**
     * @notice Enforces that the owner (DEFAULT_ADMIN_ROLE) is never also an asset manager or payment
     *         manager, and vice-versa. Every role grant — initialize, grantRole, and the 2-step admin
     *         transfer (acceptDefaultAdminTransfer) — routes through here. (An account may hold both
     *         ASSET_MANAGER_ROLE and PAYMENT_MANAGER_ROLE; only the owner must be distinct.)
     */
    function _grantRole(bytes32 role, address account) internal virtual override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE) {
            if (hasRole(ASSET_MANAGER_ROLE, account) || hasRole(PAYMENT_MANAGER_ROLE, account)) {
                revert OwnerAndManagerMustDiffer();
            }
        } else if (role == ASSET_MANAGER_ROLE || role == PAYMENT_MANAGER_ROLE) {
            if (hasRole(DEFAULT_ADMIN_ROLE, account)) {
                revert OwnerAndManagerMustDiffer();
            }
        }
        return super._grantRole(role, account);
    }

    /**
     * @notice Auto-wraps any incoming ETH into WETH so the vault only ever holds ERC-20 balances
     *         (all payments and asset-management operate on ERC-20s). Matches a wallet "Send ETH"
     *         with empty calldata.
     * @dev Skips wrapping when the sender is the WETH contract itself (which forwards ETH on unwrap),
     *      or when WETH is unset (pre-initialize), so those transfers are simply accepted as ETH.
     */
    receive() external payable {
        address weth = _vault.weth;
        if (msg.value > 0 && weth != address(0) && msg.sender != weth) {
            WETH(payable(weth)).deposit{value: msg.value}();
        }
    }

    /**
     * @notice Forwards asset-management calls (selectors not defined on this contract) to the DeFi
     *         facet by delegatecall, so they execute in this vault's storage and role context.
     */
    fallback() external payable {
        address facet = _defiFacet;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function initialize(
        address owner,
        address guardAddress,
        address weth,
        address[] memory assetAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols,
        address defiFacet
    ) public initializer {
        _defiFacet = defiFacet;
        _vault.weth = weth;
        __AccessControl_init();
        __AccessControlDefaultAdminRules_init(OWNER_TRANSFER_DELAY, owner);

        _vault.initialize(guardAddress);
        if (assetAddresses.length > 0) {
            _vault.addAssets(assetAddresses);
        }

        _assetManager.initialize(guardAddress);
        if (lendingProtocols.length > 0) {
            _assetManager.addLendingProtocols(lendingProtocols);
        }
        if (stakingProtocols.length > 0) {
            _assetManager.addStakingProtocols(stakingProtocols);
        }
        if (ammProtocols.length > 0) {
            _assetManager.addAMMProtocols(ammProtocols);
        }
        if (intentProtocols.length > 0) {
            _assetManager.addIntentProtocols(intentProtocols);
        }
    }

    // ============ Asset config ============

    function addAssets(address[] memory assetAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.addAssets(assetAddresses);
        emit AssetsAdded(assetAddresses);
    }

    function removeAssets(address[] memory assetAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.removeAssets(assetAddresses);
        emit AssetsRemoved(assetAddresses);
    }

    // irreversible — DEFAULT_ADMIN_ROLE only
    function disableAddingAssets() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.disableAddingAssets();
        emit AssetsLocked();
    }

    function isAddingAssetsDisabled() external view returns (bool) {
        return _vault.addingAssetsDisabled;
    }

    // ============ Protocol config (adding lock) ============

    function disableAddingProtocols() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.disableAddingProtocols();
        emit ProtocolsLocked();
    }

    function isAddingProtocolsDisabled() external view returns (bool) {
        return _assetManager.addingProtocolsDisabled;
    }

    /**
     * @notice Disable the owner from managing assets.
     * @dev Irreversible — once dropped, only explicit ASSET_MANAGER_ROLE holders can manage assets.
     */
    function disableOwnerAssetManager() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.ownerAssetManagerDisabled = true;
        emit OwnerAssetManagerDisabled();
    }

    function isOwnerAssetManagerDisabled() external view returns (bool) {
        return _assetManager.ownerAssetManagerDisabled;
    }

    // ============ Sending ============

    function send(address recipient, address asset, uint256 amount) external override onlyOwnerOrPaymentManager {
        if (_byOwner()) {
            _vault.send(recipient, asset, amount);
        } else {
            _vault.proposeSend(recipient, asset, amount);
        }
    }

    function disableSending() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.disableSending();
    }

    function isSendingDisabled() external view returns (bool) {
        return _vault.sendingDisabled;
    }

    function approveSend(uint256 id) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.approveSend(id);
    }

    function cancelSend(uint256 id) external override onlyOwnerOrPaymentManager {
        _vault.cancelSend(id, _byOwner());
    }

    // ============ ScheduledPayments ============

    function addScheduledPayment(
        string memory scheduledPaymentName,
        IBittyV1Vault.ScheduledPayment calldata scheduledPayment_
    ) external override onlyOwnerOrPaymentManager {
        _vault.addScheduledPayment(scheduledPaymentName, scheduledPayment_, _byOwner());
    }

    function updateScheduledPayment(
        string memory scheduledPaymentName,
        IBittyV1Vault.ScheduledPayment calldata scheduledPayment_
    ) external override onlyOwnerOrPaymentManager {
        _vault.updateScheduledPayment(scheduledPaymentName, scheduledPayment_, _byOwner());
    }

    function removeScheduledPayment(string memory scheduledPaymentName) external override onlyOwnerOrPaymentManager {
        _vault.removeScheduledPayment(scheduledPaymentName, _byOwner());
    }

    function approveScheduledPayment(string memory scheduledPaymentName)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.approveScheduledPayment(scheduledPaymentName);
    }

    // DEFAULT_ADMIN_ROLE — controls the time-lock window for new scheduled payments and whitelisted recipients
    function setNewAddressProtection(uint256 newAddressProtection) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setNewAddressProtection(newAddressProtection);
    }

    function payScheduled(string memory scheduledPaymentName) external {
        _vault.payScheduled(scheduledPaymentName);
    }

    function payScheduledAmount(string memory scheduledPaymentName, uint256 amount) external {
        _vault.payScheduledAmount(scheduledPaymentName, amount);
    }

    /**
     * @notice Pay a scheduledPayment its full scheduled amount straight out of a staked position.
     * @dev The reserve keeps earning yield until payment time, and the unstaked asset is
     * delivered directly to the configured scheduledPayment in a single step. The recipient is
     * hard-sourced from the scheduledPayment config (not a parameter), so funds can only ever reach
     * a configured scheduledPayment, never an arbitrary address. Authorization mirrors
     * {payScheduled} (the scheduledPayment's trigger, or anyone if unset).
     */
    function payScheduledFromStaking(string memory scheduledPaymentName, address stakingProtocol) external {
        (address scheduledPaymentAddress, address assetAddress, uint256 payAmount) =
            _vault.accrueScheduledPaymentOnBehalf(scheduledPaymentName);
        _assetManager.unstake(stakingProtocol, _payoutAsset(assetAddress), payAmount, scheduledPaymentAddress);
    }

    /**
     * @notice Pay a scheduledPayment its full scheduled amount straight out of a supplied (lending)
     * position. See {payScheduledFromStaking} for the recipient-safety guarantees — they
     * apply identically here.
     */
    function payScheduledFromLending(string memory scheduledPaymentName, address lendingProtocol) external {
        (address scheduledPaymentAddress, address assetAddress, uint256 payAmount) =
            _vault.accrueScheduledPaymentOnBehalf(scheduledPaymentName);
        _assetManager.withdraw(lendingProtocol, _payoutAsset(assetAddress), payAmount, scheduledPaymentAddress);
    }

    // An ETH (address(0)) scheduled payment is delivered as WETH out of the yield-position paths.
    function _payoutAsset(address assetAddress) private view returns (address) {
        return assetAddress == address(0) ? _vault.weth : assetAddress;
    }

    /**
     * @notice Pay a scheduledPayment its full scheduled amount by swapping a vault asset into the scheduledPayment's
     * asset and delivering it directly. The swap buys exactly the scheduled amount (exact-output,
     * spending ≤ `sellAmountMax` of `fromAsset`) and settles it straight to the configured scheduledPayment in
     * a single step. As with {payScheduledFromLending}/{payScheduledFromStaking}, the recipient is
     * hard-sourced from the scheduledPayment config, so funds can only ever reach a configured scheduledPayment.
     * @param scheduledPaymentName  The configured scheduledPayment to pay.
     * @param ammProtocol   The AMM protocol to route the swap through.
     * @param fromAsset     The vault asset spent to buy the scheduledPayment's asset.
     * @param sellAmountMax The maximum amount of `fromAsset` to spend (slippage bound).
     * @param data          abi.encode(fromAsset, sellAmountMax, scheduledPaymentAsset, payAmount, reversedPath).
     */
    function payScheduledFromSwap(
        string memory scheduledPaymentName,
        address ammProtocol,
        address fromAsset,
        uint256 sellAmountMax,
        bytes memory data
    ) external {
        (address scheduledPaymentAddress, address assetAddress, uint256 payAmount) =
            _vault.accrueScheduledPaymentOnBehalf(scheduledPaymentName);
        _assetManager.buyForScheduledPayment(
            _vault,
            ammProtocol,
            fromAsset,
            _payoutAsset(assetAddress),
            payAmount,
            sellAmountMax,
            scheduledPaymentAddress,
            data
        );
    }

    // ============ Whitelisted recipients (DEFAULT_ADMIN_ROLE) ============

    function addWhitelistedRecipient(string memory recipientName, address recipient, address allowedAsset)
        external
        override
        onlyOwnerOrPaymentManager
    {
        _vault.addWhitelistedRecipient(recipientName, recipient, allowedAsset, _byOwner());
    }

    function updateWhitelistedRecipient(string memory recipientName, address recipient, address allowedAsset)
        external
        override
        onlyOwnerOrPaymentManager
    {
        _vault.updateWhitelistedRecipient(recipientName, recipient, allowedAsset, _byOwner());
    }

    function removeWhitelistedRecipient(string memory recipientName) external override onlyOwnerOrPaymentManager {
        _vault.removeWhitelistedRecipient(recipientName, _byOwner());
    }

    function approveWhitelistedRecipient(string memory recipientName) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.approveWhitelistedRecipient(recipientName);
    }

    function sendToWhitelistedRecipient(string memory recipientName, address asset, uint256 amount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.sendToWhitelistedRecipient(recipientName, asset, amount);
    }

    function getWhitelistedRecipient(string memory recipientName)
        external
        view
        returns (address recipient, address allowedAsset)
    {
        return _vault.getWhitelistedRecipient(recipientName);
    }

    // ============ Protocol management & asset-manager guardrails (DEFAULT_ADMIN_ROLE) ============

    /**
     * @notice Set the minimum balance that must remain after any sell of `assetAddress` (0 disables).
     */
    function setMinimalBalance(address assetAddress, uint256 newMinimalBalance)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.setMinimalBalance(assetAddress, newMinimalBalance);
        emit MinimalBalanceSet(assetAddress, newMinimalBalance);
    }

    /**
     * @notice Set a per-asset-manager trade guardrail (throttle, per-trade cap, invested budget, expiry).
     */
    function setTradeLimit(
        address assetManager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 maxStableCoinInvestedTotal,
        uint256 expiredAt
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.setTradeLimit(
            assetManager, interval, maxStableCoinPerTrade, maxStableCoinInvestedTotal, expiredAt
        );
        emit TradeLimitSet(assetManager, interval, maxStableCoinPerTrade, maxStableCoinInvestedTotal, expiredAt);
    }

    function addLendingProtocols(address[] memory lendingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addLendingProtocols(lendingProtocolAddresses);
        emit LendingProtocolsAdded(lendingProtocolAddresses);
    }

    function removeLendingProtocols(address[] memory lendingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.removeLendingProtocols(lendingProtocolAddresses);
        emit LendingProtocolsRemoved(lendingProtocolAddresses);
    }

    function addStakingProtocols(address[] memory stakingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addStakingProtocols(stakingProtocolAddresses);
        emit StakingProtocolsAdded(stakingProtocolAddresses);
    }

    function removeStakingProtocols(address[] memory stakingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.removeStakingProtocols(stakingProtocolAddresses);
        emit StakingProtocolsRemoved(stakingProtocolAddresses);
    }

    function addAMMProtocols(address[] memory ammProtocolAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.addAMMProtocols(ammProtocolAddresses);
        emit AMMProtocolsAdded(ammProtocolAddresses);
    }

    function removeAMMProtocols(address[] memory ammProtocolAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.removeAMMProtocols(ammProtocolAddresses);
        emit AMMProtocolsRemoved(ammProtocolAddresses);
    }

    function addIntentProtocols(address[] memory intentProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addIntentProtocols(intentProtocolAddresses);
        emit IntentProtocolsAdded(intentProtocolAddresses);
    }

    function removeIntentProtocols(address[] memory intentProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.removeIntentProtocols(intentProtocolAddresses);
        emit IntentProtocolsRemoved(intentProtocolAddresses);
    }

    // ============ Views ============

    function wethAddress() external view returns (address) {
        return _vault.weth;
    }

    function getAssets() external view returns (address[] memory) {
        return _vault.getAssets();
    }

    function getStableCoins() external view returns (address[] memory) {
        return _vault.getStableCoins();
    }
}
