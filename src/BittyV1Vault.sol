// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {WETH} from "solmate/tokens/WETH.sol";
import {BittyV1VaultBase} from "./BittyV1VaultBase.sol";
import {
    IBittyV1Vault,
    ScheduledPaymentNotFound,
    OnlyScheduledPayment,
    AddressZero
} from "./interfaces/IBittyV1Vault.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";

/**
 * @title BittyV1Vault
 * @notice The core custody + payments contract: asset allowlist, scheduled payments, whitelisted
 *         recipients and micro-payments. Asset-management (trading, yield, protocols) lives in
 *         {BittyV1VaultDeFiFacet}, reached through this contract's fallback.
 * @dev
 * Best practices:
 * - DEFAULT_ADMIN_ROLE: hardware wallet / multi-sig. Owns all config and irreversible ops.
 *   Managed via {AccessControlDefaultAdminRulesUpgradeable} (2-step transfer + delay).
 * - ASSET_MANAGER_ROLE: hot wallet / AI agent. Executes yield and trading operations only.
 */
contract BittyV1Vault is BittyV1VaultBase, IBittyV1Vault {
    using AssetManagerLogic for AssetManagerStorage;

    using VaultLogic for VaultStorage;

    string public vaultName;

    address internal _weth;

    /**
     * @notice Auto-wraps any incoming ETH into WETH so the vault only ever holds ERC-20 balances
     *         (all payments and asset-management operate on ERC-20s). Matches a wallet "Send ETH"
     *         with empty calldata.
     * @dev Skips wrapping when the sender is the WETH contract itself (which forwards ETH on unwrap),
     *      or when WETH is unset (pre-initialize), so those transfers are simply accepted as ETH.
     */
    receive() external payable {
        address weth = _weth;
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
        string memory initialName,
        address[] memory assetManagers,
        address guardAddress,
        address weth,
        address[] memory assetAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols,
        address defiFacet
    ) public initializer {
        if (owner == address(0)) revert AddressZero();
        _defiFacet = defiFacet;
        _weth = weth;
        vaultName = initialName;
        __AccessControl_init();
        __AccessControlDefaultAdminRules_init(OWNER_TRANSFER_DELAY, owner);

        for (uint256 i = 0; i < assetManagers.length; i++) {
            if (assetManagers[i] != address(0)) {
                _grantRole(ASSET_MANAGER_ROLE, assetManagers[i]);
            }
        }

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

    function setName(string memory newName) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        vaultName = newName;
        emit NameSet(newName);
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

    function isAddingAssetsDisabled() external view override returns (bool) {
        return _vault.addingAssetsDisabled;
    }

    // ============ Protocol config (adding lock) ============

    function disableAddingProtocols() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.disableAddingProtocols();
        emit ProtocolsLocked();
    }

    function isAddingProtocolsDisabled() external view override returns (bool) {
        return _assetManager.addingProtocolsDisabled;
    }

    // ============ ScheduledPayments ============

    function addScheduledPayment(
        string memory scheduledPaymentName,
        IBittyV1Vault.ScheduledPayment calldata scheduledPayment_
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.addScheduledPayment(scheduledPaymentName, scheduledPayment_);
    }

    function updateScheduledPayment(
        string memory scheduledPaymentName,
        IBittyV1Vault.ScheduledPayment calldata scheduledPayment_
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.updateScheduledPayment(scheduledPaymentName, scheduledPayment_);
    }

    function removeScheduledPayment(string memory scheduledPaymentName) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.removeScheduledPayment(scheduledPaymentName);
    }

    // DEFAULT_ADMIN_ROLE — controls the time-lock window for new scheduled payments and whitelisted recipients
    function setNewAddressProtection(uint256 newAddressProtection) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setNewAddressProtection(newAddressProtection);
    }

    function changeScheduledPaymentAddress(string memory scheduledPaymentName, address newScheduledPaymentAddress)
        external
        override
    {
        address oldScheduledPaymentAddress = _vault.getScheduledPaymentAddress(scheduledPaymentName);
        if (oldScheduledPaymentAddress == address(0)) revert ScheduledPaymentNotFound();
        if (oldScheduledPaymentAddress != msg.sender) revert OnlyScheduledPayment();
        _vault.changeScheduledPaymentAddress(scheduledPaymentName, newScheduledPaymentAddress);
    }

    function payScheduled(string memory scheduledPaymentName) external override {
        _vault.payScheduled(scheduledPaymentName);
    }

    function payScheduledAmount(string memory scheduledPaymentName, uint256 amount) external override {
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
    function payScheduledFromStaking(string memory scheduledPaymentName, address stakingProtocol) external override {
        (address scheduledPaymentAddress, address assetAddress, uint256 payAmount) =
            _vault.accrueScheduledPaymentOnBehalf(scheduledPaymentName);
        _assetManager.unstake(stakingProtocol, assetAddress, payAmount, scheduledPaymentAddress);
    }

    /**
     * @notice Pay a scheduledPayment its full scheduled amount straight out of a supplied (lending)
     * position. See {payScheduledFromStaking} for the recipient-safety guarantees — they
     * apply identically here.
     */
    function payScheduledFromLending(string memory scheduledPaymentName, address lendingProtocol) external override {
        (address scheduledPaymentAddress, address assetAddress, uint256 payAmount) =
            _vault.accrueScheduledPaymentOnBehalf(scheduledPaymentName);
        _assetManager.withdraw(lendingProtocol, assetAddress, payAmount, scheduledPaymentAddress);
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
    ) external override {
        (address scheduledPaymentAddress, address assetAddress, uint256 payAmount) =
            _vault.accrueScheduledPaymentOnBehalf(scheduledPaymentName);
        _assetManager.buyForScheduledPayment(
            _vault, ammProtocol, fromAsset, assetAddress, payAmount, sellAmountMax, scheduledPaymentAddress, data
        );
    }

    // ============ Micro-payment ============

    /**
     * @notice Send stablecoin from the vault straight to any address. Callable by holders of
     * {MICRO_PAYMENT_ROLE} (a dedicated spending role, not the owner), subject to the per-payment
     * cap and interval configured by the owner.
     */
    function payMicro(address stableCoin, address to, uint256 amount) external override onlyRole(MICRO_PAYMENT_ROLE) {
        _vault.payMicro(stableCoin, to, amount);
    }

    /**
     * @notice Set a specific micro-payer's per-payment cap (in whole tokens) and minimum interval.
     * @dev Owner-only — the owner sets each payer's guardrails; a separate {MICRO_PAYMENT_ROLE} holder
     * spends within the cap configured for its own address (0 disables that payer).
     */
    function setMicroPaymentLimit(address payer, uint256 maxWholeTokens, uint256 interval)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.setMicroPaymentLimit(payer, maxWholeTokens, interval);
    }

    function getMicroPaymentLimit(address payer)
        external
        view
        override
        returns (uint256 maxWholeTokens, uint256 interval, uint256 lastTimestamp)
    {
        return _vault.getMicroPaymentLimit(payer);
    }

    // ============ Whitelisted recipients (DEFAULT_ADMIN_ROLE) ============

    function addWhitelistedRecipient(string memory name, address recipient, address allowedAsset)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.addWhitelistedRecipient(name, recipient, allowedAsset);
    }

    function updateWhitelistedRecipient(string memory name, address recipient, address allowedAsset)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.updateWhitelistedRecipient(name, recipient, allowedAsset);
    }

    function removeWhitelistedRecipient(string memory name) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.removeWhitelistedRecipient(name);
    }

    function sendToWhitelistedRecipient(string memory name, address asset, uint256 amount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.sendToWhitelistedRecipient(name, asset, amount);
    }

    function getWhitelistedRecipient(string memory name)
        external
        view
        override
        returns (address recipient, address allowedAsset)
    {
        return _vault.getWhitelistedRecipient(name);
    }

    // ============ Views ============

    function name() external view override returns (string memory) {
        return vaultName;
    }

    function wethAddress() external view returns (address) {
        return _weth;
    }

    function getAssets() external view override returns (address[] memory) {
        return _vault.getAssets();
    }

    function getStableCoins() external view override returns (address[] memory) {
        return _vault.getStableCoins();
    }
}
