// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IGrantor} from "./interfaces/IGrantor.sol";
import {IAssetManager} from "./interfaces/IAssetManager.sol";
import {IWhiteList} from "./interfaces/IWhiteList.sol";
import {IVault} from "./interfaces/IVault.sol";
import {AddressZero, OnlyGrantor, OnlyAssetManager} from "./interfaces/Errors.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";

/**
 * @title BittyVault
 * @notice
 * @dev
 */
contract BittyVault is IAssetManager, IVault, IGrantor {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;
    AssetManagerStorage internal _assetManager;
    VaultStorage internal _vault;
    modifier onlyGrantor() {
        _onlyGrantor();
        _;
    }

    function _onlyGrantor() internal view {
        if (msg.sender != _vault.grantor) revert OnlyGrantor();
    }

    modifier onlyAssetManager() {
        _onlyAssetManager();
        _;
    }

    function _onlyAssetManager() internal view {
        if (msg.sender != _assetManager.assetManager) revert OnlyAssetManager();
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
        address wethAddress_,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory yieldProviders,
        address[] memory swapProviders
    ) external {
        _vault.initialize(grantorAddress, wethAddress_, whiteListAddress);
        _vault.addAssets(assetAddresses);
        _vault.addStableCoins(stableCoinAddresses);
        _assetManager.initialize(whiteListAddress);
        _assetManager.addYieldProviders(yieldProviders);
        _assetManager.addSwapProviders(swapProviders);
    }

    // ============ IGrantor Interface ============

    function changeGrantorAddress(address grantorAddress) external override onlyGrantor {
        _vault.changeGrantorAddress(grantorAddress);
    }

    // ============ IAssetManager Interface ============

    function setAssetManager(address managerAddress) external override onlyGrantor {
        if (managerAddress == address(0)) {
            revert AddressZero();
        }
        _assetManager.setAssetManager(managerAddress);
    }

    function setManageFee(IAssetManager.ManageFee memory manageFee) external override onlyGrantor {
        _assetManager.setManageFee(manageFee);
    }

    function getYieldProviders() external view override returns (address[] memory) {
        return _assetManager.getYieldProviders();
    }

    function getSwapProviders() external view override returns (address[] memory) {
        return _assetManager.getSwapProviders();
    }

    function setRebalanceRules(IAssetManager.RebalanceLimit memory _rebalanceLimit) external override onlyGrantor {
        _assetManager.setRebalanceRules(_rebalanceLimit);
    }

    function setAssetConfig(address assetAddress, IAssetManager.AssetConfig memory _assetConfig)
        external
        override
        onlyGrantor
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

    function getBaseFee(address stableCoinAddress) external override(IAssetManager) onlyAssetManager {
        _assetManager.getBaseFee(_vault, stableCoinAddress);
    }

    function getRevenueFee(address stableCoinAddress) external override(IAssetManager) onlyAssetManager {
        _assetManager.getRevenueFee(_vault, stableCoinAddress);
    }

    function addYieldProviders(address[] memory yieldProviderAddresses) external override onlyGrantor {
        _assetManager.addYieldProviders(yieldProviderAddresses);
    }

    function removeYieldProviders(address[] memory yieldProviderAddresses) external override onlyGrantor {
        _assetManager.removeYieldProviders(yieldProviderAddresses);
    }

    function addSwapProviders(address[] memory swapProviderAddresses) external override onlyGrantor {
        _assetManager.addSwapProviders(swapProviderAddresses);
    }

    function removeSwapProviders(address[] memory swapProviderAddresses) external override onlyGrantor {
        _assetManager.removeSwapProviders(swapProviderAddresses);
    }
    // ============ IVault Interface ============

    function withdraw(address assetAddress, uint256 amount) external override onlyGrantor {
        _vault.withdraw(assetAddress, amount, _vault.grantor);
    }

    function addAssets(address[] memory assetAddresses) external override onlyGrantor {
        _vault.addAssets(assetAddresses);
    }

    function removeAssets(address[] memory assetAddresses) external override onlyGrantor {
        _vault.removeAssets(assetAddresses);
    }

    function resetAssets(address[] memory assetAddresses) external override onlyGrantor {
        _vault.resetAssets(assetAddresses);
    }

    function addStableCoins(address[] memory stableCoinAddresses) external override onlyGrantor {
        _vault.addStableCoins(stableCoinAddresses);
    }

    function removeStableCoins(address[] memory stableCoinAddresses) external override onlyGrantor {
        _vault.removeStableCoins(stableCoinAddresses);
    }

    function resetStableCoins(address[] memory stableCoinAddresses) external override onlyGrantor {
        _vault.resetStableCoins(stableCoinAddresses);
    }

    function getAssets() external view override returns (address[] memory) {
        return _vault.getAssets();
    }

    function getStableCoins() external view override returns (address[] memory) {
        return _vault.getStableCoins();
    }

    // ============ View Interface ============
    function grantor() external view returns (address) {
        return _vault.grantor;
    }

    function assetManager() external view returns (address) {
        return _assetManager.assetManager;
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
}
