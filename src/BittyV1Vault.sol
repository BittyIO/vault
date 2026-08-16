// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {WETH} from "solmate/tokens/WETH.sol";
import {BittyV1VaultBase} from "./BittyV1VaultBase.sol";
import {IBittyV1Owner} from "./interfaces/IBittyV1Owner.sol";
import {IBittyV1PayoutOperator} from "./interfaces/IBittyV1PayoutOperator.sol";
import {
    IBittyV1Vault,
    AddressZero,
    ArrayLengthMismatch,
    OwnerAndPayoutOperatorMustDiffer,
    NotPayoutOperator,
    RiskControlLevel,
    AutoYieldRoute
} from "./interfaces/IBittyV1Vault.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultStorage, AssetManagerStorage} from "./logic/Storages.sol";

/**
 * @title BittyV1Vault
 * @notice Core custody + payments: asset allowlist, scheduled payments and whitelisted recipients.
 *         Asset manager trading/yield lives in {BittyV1VaultDeFiFacet}, reached through this contract's fallback.
 */
contract BittyV1Vault is BittyV1VaultBase, IBittyV1Owner, IBittyV1PayoutOperator {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;

    // {autoYield} may only be invoked by the vault itself (from {receive}) or the owner-set trigger.
    error NotAutoYieldTrigger();

    modifier onlyOwnerOrPayoutOperator() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) && !_vault.isPayoutOperator(_msgSender())) {
            revert NotPayoutOperator();
        }
        _;
    }

    function _byOwner() private view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    function renounceVaultOwnership(uint256 rescueScheduledPaymentId) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.prepareRenounce(rescueScheduledPaymentId);
        address formerOwner = _msgSender();
        _renounceOwner();
        emit OwnershipRenounced(formerOwner);
    }

    receive() external payable {
        address weth = _vault.weth;
        if (msg.value > 0 && weth != address(0) && msg.sender != weth) {
            WETH(payable(weth)).deposit{value: msg.value}();
            try this.autoYield(weth) {} catch {}
        }
    }

    /**
     * @notice Sweep the vault's spendable balance of `assetAddress` into its configured yield route.
     * @dev Never permissionless — a griefer could strand swap liquidity by routing on demand.
     */
    function autoYield(address assetAddress) external {
        if (msg.sender != address(this) && msg.sender != _assetManager.autoYieldTrigger) {
            revert NotAutoYieldTrigger();
        }
        _assetManager.autoYield(assetAddress);
    }

    /**
     * @notice Wrap any native ETH the vault is holding into WETH.
     * @dev receive() auto-wraps incoming ETH, but ETH can still land as raw native ETH — a deposit to
     *      the counterfactual address before the vault had code, a protocol paying out with a 2300-gas
     *      stipend (too little for receive() to wrap), a force-send, or ETH sent with calldata. The
     *      vault's WETH-denominated accounting can't spend raw ETH, so this converts it. Permissionless —
     *      it only moves the vault's own ETH into its own WETH.
     */
    function ETHToWETH() external {
        address weth = _vault.weth;
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0 && weth != address(0)) {
            WETH(payable(weth)).deposit{value: ethBalance}();
        }
    }

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
        RiskControlLevel riskLevel,
        AutoYieldRoute[] memory autoYieldRoutes,
        address autoYieldTrigger
    ) public initializer {
        _defiFacet = defiFacet;
        _vault.weth = weth;
        __AccessControl_init();
        _initOwner(owner);

        _vault.initialize(guardAddress, riskLevel);
        if (assetAddresses.length > 0) {
            _vault.addAssets(assetAddresses);
        }

        _assetManager.initialize(guardAddress);

        _assetManager.setAssetManager(owner);

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

        _assetManager.autoYieldTrigger = autoYieldTrigger;
        for (uint256 i = 0; i < autoYieldRoutes.length; i++) {
            _assetManager.registerAutoYieldRoute(_vault, autoYieldRoutes[i]);
        }

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0 && weth != address(0)) {
            WETH(payable(weth)).deposit{value: ethBalance}();
        }

        // Route deposited (and just-wrapped) balances into their configured yield routes atomically.
        for (uint256 i = 0; i < autoYieldRoutes.length; i++) {
            _assetManager.autoYield(autoYieldRoutes[i].asset);
        }
    }

    function updateAssets(address[] memory addAssets, address[] memory removeAssets)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.addAssets(addAssets);
        _vault.removeAssets(removeAssets);
        emit AssetsUpdated(addAssets, removeAssets);
    }

    function disableAddingAssets() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.disableAddingAssets();
        emit AssetsLocked();
    }

    function isAddingAssetsDisabled() external view returns (bool) {
        return _vault.addingAssetsDisabled;
    }

    function disableAddingProtocols() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.disableAddingProtocols();
        emit ProtocolsLocked();
    }

    function isAddingProtocolsDisabled() external view returns (bool) {
        return _assetManager.addingProtocolsDisabled;
    }

    function send(
        address[] calldata recipients,
        address[] calldata assets,
        uint256[] calldata amounts,
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) external override onlyOwnerOrPayoutOperator {
        if (_byOwner()) {
            _pullFromPositions(assets, stakingProtocols, stakingAmounts, lendingProtocols, lendingAmounts);
            _vault.send(recipients, assets, amounts);
        } else {
            _vault.proposeSend(recipients, assets, amounts);
        }
    }

    /**
     * @dev Unstake / withdraw each row's `assets[i]` from its position into the vault before a send.
     *      No-op when all position arrays are empty; otherwise all four must equal `assets.length`.
     */
    function _pullFromPositions(
        address[] calldata assets,
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) private {
        if (
            stakingProtocols.length == 0 && stakingAmounts.length == 0 && lendingProtocols.length == 0
                && lendingAmounts.length == 0
        ) {
            return;
        }
        uint256 n = assets.length;
        if (
            stakingProtocols.length != n || stakingAmounts.length != n || lendingProtocols.length != n
                || lendingAmounts.length != n
        ) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i = 0; i < n; i++) {
            _pullOneFromPositions(
                assets[i], stakingProtocols[i], stakingAmounts[i], lendingProtocols[i], lendingAmounts[i]
            );
        }
    }

    /**
     * @dev `address(0)` protocol or `0` amount skips that leg.
     */
    function _pullOneFromPositions(
        address assetAddress,
        address stakingProtocol,
        uint256 stakingAmount,
        address lendingProtocol,
        uint256 lendingAmount
    ) private {
        address asset = _payoutAsset(assetAddress);
        if (stakingProtocol != address(0) && stakingAmount > 0) {
            _assetManager.unstake(stakingProtocol, asset, stakingAmount, address(this));
        }
        if (lendingProtocol != address(0) && lendingAmount > 0) {
            _assetManager.withdraw(lendingProtocol, asset, lendingAmount, address(this));
        }
    }

    function approveSend(uint256 id) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.approveSend(id);
    }

    function cancelSend(uint256 id) external override onlyOwnerOrPayoutOperator {
        _vault.cancelSend(id, _byOwner());
    }

    function addScheduledPayment(IBittyV1Vault.ScheduledPayment calldata scheduledPayment_)
        external
        override
        onlyOwnerOrPayoutOperator
        returns (uint256 id)
    {
        return _vault.addScheduledPayment(scheduledPayment_, _byOwner());
    }

    function updateScheduledPayment(uint256 id, IBittyV1Vault.ScheduledPayment calldata scheduledPayment_)
        external
        override
        onlyOwnerOrPayoutOperator
    {
        _vault.updateScheduledPayment(id, scheduledPayment_, _byOwner());
    }

    function removeScheduledPayment(uint256 id) external override onlyOwnerOrPayoutOperator {
        _vault.removeScheduledPayment(id, _byOwner());
    }

    function approveScheduledPayment(uint256 id, bytes32 expectedHash) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.approveScheduledPayment(id, expectedHash);
    }

    function setScheduledPaymentProtection(uint256 protection) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setScheduledPaymentProtection(protection);
    }

    function setWhitelistedProtection(uint256 protection) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setWhitelistedProtection(protection);
    }

    function setMaxSendValue(uint256 value) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setMaxSendValue(value);
    }

    function setMaxSendInterval(uint256 value) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setMaxSendInterval(value);
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
            uint64 scheduledPaymentProtection,
            uint64 whitelistedProtection,
            uint64 maxSendValue,
            uint64 maxScheduledValue,
            uint64 maxWhitelistedValue,
            uint64 changeTimelock,
            uint64 maxSendInterval
        )
    {
        return _vault.getRiskConfig();
    }

    function getRiskControlLevel() external view returns (RiskControlLevel) {
        return _vault.getRiskControlLevel();
    }

    function payScheduled(uint256 id) external {
        _vault.payScheduled(id);
    }

    function payScheduledAmount(uint256 id, uint256 amount) external {
        _vault.payScheduledAmount(id, amount);
    }

    /**
     * @notice Pay a scheduled payment straight out of a staked position; recipient is sourced from config.
     * @dev Only works for protocols whose unstake settles synchronously to a recipient.
     */
    function payScheduledFromStaking(uint256 id, address stakingProtocol) external {
        (address scheduledPaymentAddress, address assetAddress, uint256 payAmount) =
            _vault.accrueScheduledPaymentOnBehalf(id);
        _assetManager.unstake(stakingProtocol, _payoutAsset(assetAddress), payAmount, scheduledPaymentAddress);
    }

    /**
     * @notice Pay a scheduled payment straight out of a supplied (lending) position.
     * @dev See {payScheduledFromStaking} for recipient-safety guarantees.
     */
    function payScheduledFromLending(uint256 id, address lendingProtocol) external {
        (address scheduledPaymentAddress, address assetAddress, uint256 payAmount) =
            _vault.accrueScheduledPaymentOnBehalf(id);
        _assetManager.withdraw(lendingProtocol, _payoutAsset(assetAddress), payAmount, scheduledPaymentAddress);
    }

    /**
     * @dev ETH (address(0)) scheduled payments use WETH on yield-position payout paths.
     */
    function _payoutAsset(address assetAddress) private view returns (address) {
        return assetAddress == address(0) ? _vault.weth : assetAddress;
    }

    function addWhitelistedRecipient(address recipient, address allowedAsset)
        external
        override
        onlyOwnerOrPayoutOperator
        returns (uint256 id)
    {
        return _vault.addWhitelistedRecipient(recipient, allowedAsset, _byOwner());
    }

    function updateWhitelistedRecipient(uint256 id, address recipient, address allowedAsset)
        external
        override
        onlyOwnerOrPayoutOperator
    {
        _vault.updateWhitelistedRecipient(id, recipient, allowedAsset, _byOwner());
    }

    function removeWhitelistedRecipient(uint256 id) external override onlyOwnerOrPayoutOperator {
        _vault.removeWhitelistedRecipient(id, _byOwner());
    }

    function approveWhitelistedRecipient(uint256 id, bytes32 expectedHash)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.approveWhitelistedRecipient(id, expectedHash);
    }

    function sendToWhitelistedRecipient(
        uint256 id,
        address asset,
        uint256 amount,
        address stakingProtocol,
        uint256 stakingAmount,
        address lendingProtocol,
        uint256 lendingAmount
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pullOneFromPositions(asset, stakingProtocol, stakingAmount, lendingProtocol, lendingAmount);
        _vault.sendToWhitelistedRecipient(id, asset, amount);
    }

    function getWhitelistedRecipient(uint256 id) external view returns (address recipient, address allowedAsset) {
        return _vault.getWhitelistedRecipient(id);
    }

    function setMinimalBalance(address assetAddress, uint256 newMinimalBalance)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.setMinimalBalance(assetAddress, newMinimalBalance);
        emit MinimalBalanceSet(assetAddress, newMinimalBalance);
    }

    function setAutoYielding(address assetAddress, address protocol, bool isSupplying)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.setAutoYielding(assetAddress, protocol, isSupplying);
    }

    function getAutoYielding(address assetAddress) external view returns (address protocol, bool isSupplying) {
        return _assetManager.getAutoYielding(assetAddress);
    }

    function setAutoYieldTrigger(address trigger) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.autoYieldTrigger = trigger;
        emit AutoYieldTriggerSet(trigger);
    }

    function getAutoYieldTrigger() external view returns (address) {
        return _assetManager.autoYieldTrigger;
    }

    function setAssetManager(address assetManager) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.setAssetManager(assetManager);
        emit AssetManagerSet(assetManager);
    }

    function removeAssetManager() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.removeAssetManager();
        emit AssetManagerRemoved();
    }

    function getAssetManager() external view returns (address) {
        return _assetManager.assetManager;
    }

    function addPayoutOperator(address payoutOperator) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (hasRole(DEFAULT_ADMIN_ROLE, payoutOperator)) revert OwnerAndPayoutOperatorMustDiffer();
        _vault.addPayoutOperator(payoutOperator);
    }

    function removePayoutOperator(address payoutOperator) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.removePayoutOperator(payoutOperator);
    }

    function getPayoutOperators() external view returns (address[] memory) {
        return _vault.getPayoutOperators();
    }

    function isPayoutOperator(address account) external view returns (bool) {
        return _vault.isPayoutOperator(account);
    }

    function updateLendingProtocols(address[] memory addLendingProtocols, address[] memory removeLendingProtocols)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addLendingProtocols(addLendingProtocols);
        _assetManager.removeLendingProtocols(removeLendingProtocols);
        emit LendingProtocolsUpdated(addLendingProtocols, removeLendingProtocols);
    }

    function updateStakingProtocols(address[] memory addStakingProtocols, address[] memory removeStakingProtocols)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addStakingProtocols(addStakingProtocols);
        _assetManager.removeStakingProtocols(removeStakingProtocols);
        emit StakingProtocolsUpdated(addStakingProtocols, removeStakingProtocols);
    }

    function updateAMMProtocols(address[] memory addAMMProtocols, address[] memory removeAMMProtocols)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addAMMProtocols(addAMMProtocols);
        _assetManager.removeAMMProtocols(removeAMMProtocols);
        emit AMMProtocolsUpdated(addAMMProtocols, removeAMMProtocols);
    }

    function updateIntentProtocols(address[] memory addIntentProtocols, address[] memory removeIntentProtocols)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addIntentProtocols(addIntentProtocols);
        _assetManager.removeIntentProtocols(removeIntentProtocols);
        emit IntentProtocolsUpdated(addIntentProtocols, removeIntentProtocols);
    }

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
