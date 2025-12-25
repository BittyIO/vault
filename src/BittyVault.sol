// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ITrust} from "./interfaces/ITrust.sol";
import {ITrustee} from "./interfaces/ITrustee.sol";
import {IAssetManager} from "./interfaces/IAssetManager.sol";
import {IBeneficiary} from "./interfaces/IBeneficiary.sol";
import {IWhiteList} from "./interfaces/IWhiteList.sol";
import {IVault} from "./interfaces/IVault.sol";
import {
    AddressZero,
    AlreadyInitialized,
    NotAuthorized,
    OnlyGrantor,
    OnlyTrustee,
    OnlyBeneficiary,
    OnlyAssetManager,
    OnlyRevocable
} from "./interfaces/Errors.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {TrustLogic} from "./logic/TrustLogic.sol";
import {MigratorLogic} from "./logic/MigratorLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, TrustStorage, MigratorStorage, VaultStorage} from "./logic/Storages.sol";

/**
 * @title BittyVault
 * @notice Unified vault contract that combines Asset Management and _trust Management
 * @dev
 * This contract inherits from both _assetManager and _trust, providing a single interface
 * for both asset management operations (supply, withdraw, rebalance, etc.) and _trust
 * management operations (initialize, revoke, set beneficiaries, etc.).
 */
contract BittyVault is ITrust, IAssetManager, IVault {
    using AssetManagerLogic for AssetManagerStorage;
    using TrustLogic for TrustStorage;
    using MigratorLogic for MigratorStorage;
    using VaultLogic for VaultStorage;
    uint256 public immutable override version = 1;
    address public override migrator;
    AssetManagerStorage internal _assetManager;
    TrustStorage internal _trust;
    MigratorStorage internal _migrator;
    VaultStorage internal _vault;
    modifier onlyGrantor() {
        _onlyGrantor();
        _;
    }

    function _onlyGrantor() internal view {
        if (msg.sender != _vault.grantor) revert OnlyGrantor();
    }

    modifier onlyTrustee() {
        _onlyTrustee();
        _;
    }

    function _onlyTrustee() internal view {
        if (msg.sender != _trust.trustee) revert OnlyTrustee();
    }

    modifier onlyTrusteeOrGrantor() {
        _onlyTrusteeOrGrantor();
        _;
    }

    function _onlyTrusteeOrGrantor() internal view {
        if (_trust.trustee != address(0)) {
            if (msg.sender != _trust.trustee) revert OnlyTrustee();
            return;
        }
        if (_vault.grantor != address(0)) {
            if (msg.sender != _vault.grantor) revert OnlyGrantor();
            return;
        }
        revert NotAuthorized();
    }

    modifier onlyAssetManager() {
        _onlyAssetManager();
        _;
    }

    function _onlyAssetManager() internal view {
        if (msg.sender != _assetManager.assetManager) revert OnlyAssetManager();
    }

    modifier onlyRevocable() {
        _onlyRevocable();
        _;
    }

    function _onlyRevocable() internal view {
        if (!this.revocable()) revert OnlyRevocable();
    }

    modifier onlyBeneficiary() {
        _onlyBeneficiary();
        _;
    }

    function _onlyBeneficiary() internal view {
        if (msg.sender != _trust.beneficiary) revert OnlyBeneficiary();
    }

    function _onlyValidAsset(VaultStorage storage vaultStorage, address assetAddress) private view {
        vaultStorage.checkAsset(assetAddress);
    }

    modifier onlyValidAsset(address assetAddress) {
        _onlyValidAsset(_vault, assetAddress);
        _;
    }

    function initialize(
        address grantorAddress,
        address whiteListAddress,
        address migratorAddress,
        address wethAddress_,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory yieldProviders,
        address[] memory swapProviders
    ) external {
        _migrator.initialize(migratorAddress);
        _vault.initialize(grantorAddress, wethAddress_, whiteListAddress);
        _vault.addAssets(assetAddresses);
        _vault.addStableCoins(stableCoinAddresses);
        _assetManager.initialize(whiteListAddress);
        _assetManager.addYieldProviders(yieldProviders);
        _assetManager.addSwapProviders(swapProviders);
        _trust.initialize();
    }

    function initializeFromPreviousVersion(
        address, /*previousVersionAddress*/
        bytes memory /*args*/
    )
        external
        pure
        override
    {
        revert AlreadyInitialized();
    }

    function createAndMigrate(uint256 _toVersion, string calldata _salt)
        external
        override
        onlyTrusteeOrGrantor
        returns (address)
    {
        address nextVault = _migrator.create(_toVersion, _salt);
        if (nextVault == address(0)) {
            revert AddressZero();
        }
        _revoke(nextVault);
        return nextVault;
    }

    function migrateAssets(uint256 _toVersion) external override onlyTrusteeOrGrantor {
        address nextVault = _migrator.versionVault(address(this), _toVersion);
        if (nextVault == address(0)) {
            revert AddressZero();
        }
        _revoke(nextVault);
    }

    function _revoke(address to) private {
        _vault.revoke(to);
    }

    // ============ IGrantor Interface ============

    function changeGrantorAddress(address grantorAddress) external override onlyGrantor onlyRevocable {
        _vault.changeGrantorAddress(grantorAddress);
    }

    function setTrustee(address trusteeAddress) external override onlyGrantor onlyRevocable {
        _trust.setTrustee(trusteeAddress);
    }

    function setTrusteeInvalidAfterNoPing(uint256 trusteeInvalidAfterNoPing)
        external
        override
        onlyGrantor
        onlyRevocable
    {
        _trust.setTrusteeInvalidAfterNoPing(trusteeInvalidAfterNoPing);
    }

    function trusteePing() external override onlyTrustee {
        _trust.trusteePing();
    }

    function setBeneficiary(address beneficiaryAddress) external override onlyGrantor onlyRevocable {
        _trust.setBeneficiary(beneficiaryAddress);
    }

    function setBeneficiarySettings(IBeneficiary.BeneficiarySettings memory _beneficiarySettings)
        external
        override
        onlyGrantor
        onlyRevocable
    {
        _trust.setBeneficiarySettings(_beneficiarySettings);
    }

    function addTriggerEvents(string[] memory eventNames, IBeneficiary.TriggerEvent[] memory triggerEvents)
        external
        override
        onlyGrantor
        onlyRevocable
    {
        _trust.addTriggerEvents(eventNames, triggerEvents);
    }

    function removeTriggerEvents(string[] memory eventNames) external override onlyGrantor onlyRevocable {
        _trust.removeTriggerEvents(eventNames);
    }

    function addTimeEvents(uint256[] memory timestamps, IBeneficiary.TimeEvent[] memory timeEvents)
        external
        override
        onlyGrantor
        onlyRevocable
    {
        _trust.addTimeEvents(timestamps, timeEvents);
    }

    function removeTimeEvents(uint256[] memory timestamps) external override onlyGrantor onlyRevocable {
        _trust.removeTimeEvents(timestamps);
    }

    function setToIrrevocable() external override onlyGrantor {
        _trust.setToIrrevocable();
    }

    function setStartDistributionTimestamp(uint256 _startDistributionTimestamp) external override onlyGrantor {
        _trust.setStartDistributionTimestamp(_startDistributionTimestamp);
    }

    function distributionStarted() external view override returns (bool) {
        return _trust.distributionStarted();
    }

    function setAutoIrrevocableAfterNoPing(uint256 pingSeconds) external override onlyGrantor onlyRevocable {
        _trust.setAutoIrrevocableAfterNoPing(pingSeconds);
    }

    function grantorPing() external override onlyGrantor {
        _trust.grantorPing();
    }

    function upgrade(address upgradeToContract) external view override onlyGrantor {
        _trust.upgrade(upgradeToContract);
    }

    // ============ IBeneficiary Interface ============

    function changeBeneficiaryAddress(address newBeneficiaryAddress) external override onlyBeneficiary {
        _trust.changeBeneficiaryAddress(newBeneficiaryAddress);
    }

    function getMoney(address stableCoinAddress) external override onlyBeneficiary {
        _trust.getMoney(_vault, stableCoinAddress);
    }

    function getMoneyFromEvent(string memory eventName, address stableCoinAddress) external override {
        _trust.getMoneyFromEvent(_vault, eventName, stableCoinAddress, _trust.beneficiary);
    }

    function getMoneyByTimestamp(uint256 timestamp, address stableCoinAddress) external override onlyBeneficiary {
        _trust.getMoneyByTimestamp(_vault, timestamp, stableCoinAddress);
    }

    function lastWithdrawalTime() external view override returns (uint256) {
        return _trust.lastWithdrawalTime;
    }

    function replaceTrustee(address newTrusteeAddress) external override onlyBeneficiary {
        _trust.replaceTrustee(_vault, newTrusteeAddress);
    }

    // ============ ITrustee Interface ============

    function changeTrusteeAddress(address newTrusteeAddress) external override onlyTrustee {
        _trust.changeTrusteeAddress(newTrusteeAddress);
    }

    function setAssetManager(address assetManagerAddress) external override onlyTrusteeOrGrantor {
        _assetManager.setAssetManager(assetManagerAddress);
    }

    function setManageFee(IAssetManager.ManageFee memory manageFee_)
        external
        override(IAssetManager, ITrustee)
        onlyTrusteeOrGrantor
    {
        _assetManager.setManageFee(manageFee_);
    }

    // ============ IAssetManager Interface ============

    function getProviderInstance(address provider) external view override returns (address) {
        return _assetManager.getProviderInstance(provider);
    }

    function getYieldProviders() external view override returns (address[] memory) {
        return _assetManager.getYieldProviders();
    }

    function getSwapProviders() external view override returns (address[] memory) {
        return _assetManager.getSwapProviders();
    }

    function setRebalanceRules(IAssetManager.RebalanceLimit memory _rebalanceLimit)
        external
        override
        onlyTrusteeOrGrantor
    {
        _assetManager.setRebalanceRules(_rebalanceLimit);
    }

    function setAssetConfig(address assetAddress, IAssetManager.AssetConfig memory _assetConfig)
        external
        override
        onlyTrusteeOrGrantor
    {
        _assetManager.setAssetConfig(assetAddress, _assetConfig);
    }

    function supply(address yieldProvider, address assetAddress, uint256 amount) external override onlyAssetManager {
        _assetManager.supply(yieldProvider, assetAddress, amount);
    }

    function withdraw(address yieldProvider, address assetAddress, uint256 amount) external override onlyAssetManager {
        _assetManager.withdraw(yieldProvider, assetAddress, amount);
    }

    function getBalance(address yieldProvider, address assetAddress) external view override returns (uint256) {
        return _assetManager.getBalance(yieldProvider, assetAddress);
    }

    function rebalance(
        address swapProvider,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external override onlyAssetManager onlyValidAsset(to) {
        _assetManager.rebalance(_vault, swapProvider, from, to, sellAmount, buyAmountMin, data);
    }

    function turnETHToWETH() external override {
        _vault.turnETHToWETH();
    }

    function getBaseFee(address stableCoinAddress) external override(IAssetManager, ITrust) onlyAssetManager {
        _assetManager.getBaseFee(_vault, stableCoinAddress);
    }

    function getRevenueFee(address stableCoinAddress) external override(IAssetManager, ITrust) onlyAssetManager {
        _assetManager.getRevenueFee(_vault, stableCoinAddress);
    }

    function addYieldProviders(address[] memory yieldProviderAddresses) external override onlyTrusteeOrGrantor {
        _assetManager.addYieldProviders(yieldProviderAddresses);
    }

    function removeYieldProviders(address[] memory yieldProviderAddresses) external override onlyTrusteeOrGrantor {
        _assetManager.removeYieldProviders(yieldProviderAddresses);
    }

    function addSwapProviders(address[] memory swapProviderAddresses) external override onlyTrusteeOrGrantor {
        _assetManager.addSwapProviders(swapProviderAddresses);
    }

    function removeSwapProviders(address[] memory swapProviderAddresses) external override onlyTrusteeOrGrantor {
        _assetManager.removeSwapProviders(swapProviderAddresses);
    }
    // ============ IVault Interface ============

    function withdraw(address assetAddress, uint256 amount) external override onlyGrantor onlyRevocable {
        _vault.withdraw(assetAddress, amount, _vault.grantor);
    }

    function revoke() external override onlyGrantor onlyRevocable {
        _revoke(_vault.grantor);
    }

    function addAssets(address[] memory assetAddresses) external override onlyTrusteeOrGrantor {
        _vault.addAssets(assetAddresses);
    }

    function removeAssets(address[] memory assetAddresses) external override onlyTrusteeOrGrantor {
        _vault.removeAssets(assetAddresses);
    }

    function resetAssets(address[] memory assetAddresses) external override onlyTrusteeOrGrantor {
        _vault.resetAssets(assetAddresses);
    }

    function addStableCoins(address[] memory stableCoinAddresses) external override onlyTrusteeOrGrantor {
        _vault.addStableCoins(stableCoinAddresses);
    }

    function removeStableCoins(address[] memory stableCoinAddresses) external override onlyTrusteeOrGrantor {
        _vault.removeStableCoins(stableCoinAddresses);
    }

    function resetStableCoins(address[] memory stableCoinAddresses) external override onlyTrusteeOrGrantor {
        _vault.resetStableCoins(stableCoinAddresses);
    }

    function getAssets() external view override returns (address[] memory) {
        return _vault.getAssets();
    }

    function getStableCoins() external view override returns (address[] memory) {
        return _vault.getStableCoins();
    }

    // ============ View Interface ============

    function revocable() external view override returns (bool) {
        return _trust.revocable();
    }

    function isIrrevocable() external view returns (bool) {
        return !_trust.revocable();
    }

    function autoIrrevocableAfterNoPing() external view returns (uint256) {
        return _trust.autoIrrevocableAfterNoPing;
    }

    function grantor() external view returns (address) {
        return _vault.grantor;
    }

    function trustee() external view returns (address) {
        return _trust.trustee;
    }

    function trusteeLastPingTime() external view returns (uint256) {
        return _trust.trusteeLastPingTime;
    }

    function beneficiary() external view returns (address) {
        return _trust.beneficiary;
    }

    function assetManager() external view returns (address) {
        return _assetManager.assetManager;
    }

    function lastPingTime() external view returns (uint256) {
        return _trust.lastPingTime;
    }

    function autoIrrevocableStartTime() external view returns (uint256) {
        return _trust.autoIrrevocableStartTime;
    }

    function beneficiarySettings() external view returns (IBeneficiary.BeneficiarySettings memory) {
        return _trust.beneficiarySettings;
    }

    function startDistributionTimestamp() external view returns (uint256) {
        return _trust.startDistributionTimestamp;
    }

    function lastBaseFeeTime() external view returns (uint256) {
        return _assetManager.lastBaseFeeTime;
    }

    function revenue() external view returns (uint256) {
        return _assetManager.revenue;
    }

    function lastRevenueTime() external view returns (uint256) {
        return _assetManager.lastRevenueTime;
    }

    function manageFee() external view returns (IAssetManager.ManageFee memory) {
        return _assetManager.manageFee;
    }

    function wethAddress() external view returns (address) {
        return _vault.weth;
    }

    function whiteList() external view returns (IWhiteList) {
        return _assetManager.whiteList;
    }

    function lastRebalanceTimestamp() external view returns (uint256) {
        return _assetManager.lastRebalanceTimestamp;
    }

    function rebalanceLimit() external view returns (IAssetManager.RebalanceLimit memory) {
        return _assetManager.rebalanceLimit;
    }

    function getAllTriggerEventKeys() external view returns (bytes32[] memory) {
        return _trust.getAllTriggerEventKeys();
    }

    function getAllTimeEventKeys() external view returns (uint256[] memory) {
        return _trust.getAllTimeEventKeys();
    }

    function getAllAssetConfigKeys() external view returns (address[] memory) {
        return _assetManager.getAllAssetConfigKeys();
    }

    function getAllLastRebalanceTimestampKeys() external view returns (address[] memory) {
        return _assetManager.getAllLastRebalanceTimestampKeys();
    }

    function lastRebalanceTimestamps(address assetAddress) external view returns (uint256) {
        return _assetManager.lastRebalanceTimestamps[assetAddress];
    }

    function assetConfigs(address assetAddress) external view returns (IAssetManager.AssetConfig memory) {
        return _assetManager.assetConfigs[assetAddress];
    }

    function beneficiaryTriggerEvents(bytes32 eventKey) external view returns (IBeneficiary.TriggerEvent memory) {
        return _trust.beneficiaryTriggerEvents[eventKey];
    }

    function beneficiaryTimeEvents(uint256 timestamp) external view returns (IBeneficiary.TimeEvent memory) {
        return _trust.beneficiaryTimeEvents[timestamp];
    }

    receive() external payable {}
}
