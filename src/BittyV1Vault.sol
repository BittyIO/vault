// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {WETH} from "solmate/tokens/WETH.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {BittyV1VaultBase} from "./BittyV1VaultBase.sol";
import {IBittyV1Owner} from "./interfaces/IBittyV1Owner.sol";
import {IBittyV1PaymentManager} from "./interfaces/IBittyV1PaymentManager.sol";
import {IBittyV1Vault, AddressZero, OwnerAndManagerMustDiffer, RiskControlLevel} from "./interfaces/IBittyV1Vault.sol";
import {CannotGrantAssetManagerRole} from "./interfaces/IBittyV1AssetManager.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage, RiskConfig} from "./logic/Storages.sol";

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
     * @notice Enforces that the owner (DEFAULT_ADMIN_ROLE) is never also a payment manager, and
     *         vice-versa — the owner already has full, immediate payment authority, so the role would
     *         be redundant. The owner MAY hold ASSET_MANAGER_ROLE (added via {addAssetManager} with a
     *         cap), which is the only way for the owner to trade. Every role grant — initialize,
     *         grantRole, and the 2-step admin transfer — routes through here.
     */
    function _grantRole(bytes32 role, address account) internal virtual override returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE) {
            if (hasRole(PAYMENT_MANAGER_ROLE, account)) {
                revert OwnerAndManagerMustDiffer();
            }
        } else if (role == PAYMENT_MANAGER_ROLE) {
            if (hasRole(DEFAULT_ADMIN_ROLE, account)) {
                revert OwnerAndManagerMustDiffer();
            }
        }
        return super._grantRole(role, account);
    }

    /**
     * @notice Blocks granting ASSET_MANAGER_ROLE directly: asset managers must be added via
     *         {addAssetManager}, which requires a non-zero invest cap, so no asset manager can ever
     *         exist without a trade limit. Other roles (e.g. PAYMENT_MANAGER_ROLE) are unaffected.
     */
    function grantRole(bytes32 role, address account) public virtual override {
        if (role == ASSET_MANAGER_ROLE) revert CannotGrantAssetManagerRole();
        super.grantRole(role, account);
    }

    /**
     * @notice Revoking ASSET_MANAGER_ROLE also clears the manager's trade limit (cap and tracked
     *         invested portfolio) so no stale invest budget is left behind if the role is later
     *         re-granted. Access control (owner-only) is enforced by the inherited revokeRole.
     */
    function revokeRole(bytes32 role, address account) public virtual override {
        super.revokeRole(role, account);
        if (role == ASSET_MANAGER_ROLE) {
            _assetManager.removeTradeLimit(account);
        }
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
        address defiFacet,
        RiskControlLevel riskLevel
    ) public initializer {
        _defiFacet = defiFacet;
        _vault.weth = weth;
        __AccessControl_init();
        __AccessControlDefaultAdminRules_init(OWNER_TRANSFER_DELAY, owner);

        _vault.initialize(guardAddress, riskLevel);
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

    function addScheduledPayment(IBittyV1Vault.ScheduledPayment calldata scheduledPayment_)
        external
        override
        onlyOwnerOrPaymentManager
        returns (uint256 id)
    {
        return _vault.addScheduledPayment(scheduledPayment_, _byOwner());
    }

    function updateScheduledPayment(uint256 id, IBittyV1Vault.ScheduledPayment calldata scheduledPayment_)
        external
        override
        onlyOwnerOrPaymentManager
    {
        _vault.updateScheduledPayment(id, scheduledPayment_, _byOwner());
    }

    function removeScheduledPayment(uint256 id) external override onlyOwnerOrPaymentManager {
        _vault.removeScheduledPayment(id, _byOwner());
    }

    function approveScheduledPayment(uint256 id) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.approveScheduledPayment(id);
    }

    // DEFAULT_ADMIN_ROLE — controls the time-lock window for new scheduled payments and whitelisted recipients
    function setNewAddressProtection(uint256 newAddressProtection) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setNewAddressProtection(newAddressProtection);
    }

    function setMaxSendValue(uint256 value) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setMaxSendValue(value);
    }

    function setMaxScheduledValue(uint256 value) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setMaxScheduledValue(value);
    }

    function setMaxWhitelistedValue(uint256 value) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setMaxWhitelistedValue(value);
    }

    function setChangeTimelock(uint256 value) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setChangeTimelock(value);
    }

    function getRiskConfig()
        external
        view
        returns (
            uint64 newAddressProtection,
            uint64 maxSendValue,
            uint64 maxScheduledValue,
            uint64 maxWhitelistedValue,
            uint64 changeTimelock
        )
    {
        return _vault.getRiskConfig();
    }

    function payScheduled(uint256 id) external {
        _vault.payScheduled(id);
    }

    function payScheduledAmount(uint256 id, uint256 amount) external {
        _vault.payScheduledAmount(id, amount);
    }

    /**
     * @notice Pay a scheduledPayment its full scheduled amount straight out of a staked position.
     * @dev The reserve keeps earning yield until payment time, and the unstaked asset is
     * delivered directly to the configured scheduledPayment in a single step. The recipient is
     * hard-sourced from the scheduledPayment config (not a parameter), so funds can only ever reach
     * a configured scheduledPayment, never an arbitrary address. Authorization mirrors
     * {payScheduled} (the scheduledPayment's trigger, or anyone if unset).
     */
    function payScheduledFromStaking(uint256 id, address stakingProtocol) external {
        (address scheduledPaymentAddress, address assetAddress, uint256 payAmount) =
            _vault.accrueScheduledPaymentOnBehalf(id);
        _assetManager.unstake(stakingProtocol, _payoutAsset(assetAddress), payAmount, scheduledPaymentAddress);
    }

    /**
     * @notice Pay a scheduledPayment its full scheduled amount straight out of a supplied (lending)
     * position. See {payScheduledFromStaking} for the recipient-safety guarantees — they
     * apply identically here.
     */
    function payScheduledFromLending(uint256 id, address lendingProtocol) external {
        (address scheduledPaymentAddress, address assetAddress, uint256 payAmount) =
            _vault.accrueScheduledPaymentOnBehalf(id);
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
     * @param id            The configured scheduledPayment to pay.
     * @param ammProtocol   The AMM protocol to route the swap through.
     * @param fromAsset     The vault asset spent to buy the scheduledPayment's asset.
     * @param sellAmountMax The maximum amount of `fromAsset` to spend (slippage bound).
     * @param data          abi.encode(fromAsset, sellAmountMax, scheduledPaymentAsset, payAmount, reversedPath).
     */
    function payScheduledFromSwap(
        uint256 id,
        address ammProtocol,
        address fromAsset,
        uint256 sellAmountMax,
        bytes memory data
    ) external {
        (address scheduledPaymentAddress, address assetAddress, uint256 payAmount) =
            _vault.accrueScheduledPaymentOnBehalf(id);
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

    function addWhitelistedRecipient(address recipient, address allowedAsset)
        external
        override
        onlyOwnerOrPaymentManager
        returns (uint256 id)
    {
        return _vault.addWhitelistedRecipient(recipient, allowedAsset, _byOwner());
    }

    function updateWhitelistedRecipient(uint256 id, address recipient, address allowedAsset)
        external
        override
        onlyOwnerOrPaymentManager
    {
        _vault.updateWhitelistedRecipient(id, recipient, allowedAsset, _byOwner());
    }

    function removeWhitelistedRecipient(uint256 id) external override onlyOwnerOrPaymentManager {
        _vault.removeWhitelistedRecipient(id, _byOwner());
    }

    function approveWhitelistedRecipient(uint256 id) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.approveWhitelistedRecipient(id);
    }

    function sendToWhitelistedRecipient(uint256 id, address asset, uint256 amount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.sendToWhitelistedRecipient(id, asset, amount);
    }

    function getWhitelistedRecipient(uint256 id) external view returns (address recipient, address allowedAsset) {
        return _vault.getWhitelistedRecipient(id);
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
     * @notice Add an asset manager and its trade guardrail atomically. Only way to grant
     *         ASSET_MANAGER_ROLE; reverts (inside setTradeLimit) if stableCoinInvestCap is 0.
     */
    function addAssetManager(
        address assetManager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(ASSET_MANAGER_ROLE, assetManager);
        _assetManager.setTradeLimit(assetManager, interval, maxStableCoinPerTrade, stableCoinInvestCap, expiredAt);
        emit TradeLimitSet(assetManager, interval, maxStableCoinPerTrade, stableCoinInvestCap, expiredAt);
    }

    /**
     * @notice Update an existing asset manager's trade guardrail (throttle, per-trade cap, invest cap,
     *         expiry). Reverts if stableCoinInvestCap is 0, so a manager can never be left uncapped.
     */
    function setTradeLimit(
        address assetManager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.setTradeLimit(assetManager, interval, maxStableCoinPerTrade, stableCoinInvestCap, expiredAt);
        emit TradeLimitSet(assetManager, interval, maxStableCoinPerTrade, stableCoinInvestCap, expiredAt);
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
