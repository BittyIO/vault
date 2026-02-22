// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IAssetManager, OnlyAssetManager} from "./interfaces/IAssetManager.sol";
import {IWhiteList} from "./interfaces/IWhiteList.sol";
import {IVault, AddressZero, ReceiverNotFound} from "./interfaces/IVault.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";
import {OnlyReceiver} from "./interfaces/IVault.sol";

/**
 * @title Vault
 * @notice
 * @dev
 */
contract Vault is IAssetManager, IVault, Initializable, Ownable {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;
    AssetManagerStorage internal _assetManager;
    VaultStorage internal _vault;

    modifier onlyAssetManager() {
        if (msg.sender != _assetManager.assetManager) revert OnlyAssetManager();
        _;
    }

    function _onlyValidAsset(VaultStorage storage vaultStorage, address assetAddress) private view {
        vaultStorage.checkAsset(assetAddress);
    }

    modifier onlyValidAsset(address assetAddress) {
        _onlyValidAsset(_vault, assetAddress);
        _;
    }

    function initialize(
        address whiteListAddress,
        address wethAddress_,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory swapProviders
    ) public initializer {
        _transferOwnership(tx.origin);
        _vault.initialize(wethAddress_, whiteListAddress);
        _vault.addAssets(assetAddresses);
        _vault.addStableCoins(stableCoinAddresses);
        _assetManager.initialize(whiteListAddress);
        _assetManager.addLendingProviders(lendingProviders);
        _assetManager.addStakingProviders(stakingProviders);
        _assetManager.addSwapProviders(swapProviders);
    }

    // ============ IAssetManager Interface ============

    function changeAssetManager(address newAssetManager) external override onlyAssetManager {
        _assetManager.setAssetManager(newAssetManager);
    }

    function getLendingProviders() external view override returns (address[] memory) {
        return _assetManager.getLendingProviders();
    }

    function getStakingProviders() external view override returns (address[] memory) {
        return _assetManager.getStakingProviders();
    }

    function getSwapProviders() external view override returns (address[] memory) {
        return _assetManager.getSwapProviders();
    }

    function setAssetConfig(address assetAddress, IAssetManager.AssetConfig memory _assetConfig)
        external
        override
        onlyOwner
    {
        _assetManager.setAssetConfig(assetAddress, _assetConfig);
    }

    function supply(address lendingProvider, address assetAddress, uint256 amount) external override onlyAssetManager {
        _assetManager.supply(lendingProvider, assetAddress, amount);
    }

    function withdraw(address lendingProvider, address assetAddress, uint256 amount)
        external
        override
        onlyAssetManager
    {
        _assetManager.withdraw(lendingProvider, assetAddress, amount);
    }

    function getLendingBalance(address lendingProvider, address assetAddress) external view override returns (uint256) {
        return _assetManager.getLendingBalance(lendingProvider, assetAddress);
    }

    function stake(address stakingProvider, uint256 amount) external override onlyAssetManager {
        _assetManager.stake(stakingProvider, _vault.weth, amount);
    }

    function unstake(address stakingProvider, uint256 amount) external override onlyAssetManager {
        _assetManager.unstake(stakingProvider, _vault.weth, amount);
    }

    function getStakingBalance(address stakingProvider) external view override returns (uint256) {
        return _assetManager.getStakingBalance(stakingProvider);
    }

    function getUnstakeRequestIds(address stakingProvider) external view override returns (uint256[] memory) {
        return _assetManager.getUnstakeRequestIds(stakingProvider);
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

    function disableRebalanceUntilTimestamp(uint256 timestamp) external override onlyAssetManager {
        _assetManager.disableRebalanceUntilTimestamp(timestamp);
    }

    function ETHToWETH(uint256 amount) external override onlyAssetManager {
        _vault.ETHToWETH(amount);
    }

    function WETHToETH(uint256 amount) external override onlyAssetManager {
        _vault.WETHToETH(amount);
    }

    function addLendingProviders(address[] memory lendingProviderAddresses) external override onlyOwner {
        _assetManager.addLendingProviders(lendingProviderAddresses);
    }

    function addStakingProviders(address[] memory stakingProviderAddresses) external override onlyOwner {
        _assetManager.addStakingProviders(stakingProviderAddresses);
    }

    function removeLendingProviders(address[] memory lendingProviderAddresses) external override onlyOwner {
        _assetManager.removeLendingProviders(lendingProviderAddresses);
    }

    function removeStakingProviders(address[] memory stakingProviderAddresses) external override onlyOwner {
        _assetManager.removeStakingProviders(stakingProviderAddresses);
    }

    function addSwapProviders(address[] memory swapProviderAddresses) external override onlyOwner {
        _assetManager.addSwapProviders(swapProviderAddresses);
    }

    function removeSwapProviders(address[] memory swapProviderAddresses) external override onlyOwner {
        _assetManager.removeSwapProviders(swapProviderAddresses);
    }

    // ============ IVault Interface ============

    function addReceiver(string memory name, IVault.Receiver calldata receiver_) external override onlyOwner {
        _vault.addReceiver(name, receiver_);
    }

    function updateReceiver(string memory name, IVault.Receiver calldata receiver_) external override onlyOwner {
        _vault.updateReceiver(name, receiver_);
    }

    function changeReceiverAddress(string memory name, address newReceiverAddress) external override {
        address oldReceiverAddress = _vault.getReceiverAddress(name);
        if (oldReceiverAddress == address(0)) {
            revert ReceiverNotFound();
        }
        if (oldReceiverAddress != msg.sender) {
            revert OnlyReceiver();
        }
        _vault.changeReceiverAddress(name, newReceiverAddress);
    }

    function removeReceiver(string memory name) external override onlyOwner {
        _vault.removeReceiver(name);
    }

    function setAssetManager(address managerAddress) external override onlyOwner {
        _assetManager.setAssetManager(managerAddress);
    }

    function addAssets(address[] memory assetAddresses) external override onlyOwner {
        _vault.addAssets(assetAddresses);
    }

    function disableAddingAssets() external override onlyOwner {
        _vault.disableAddingAssets();
    }

    function removeAssets(address[] memory assetAddresses) external override onlyOwner {
        _vault.removeAssets(assetAddresses);
    }

    function resetAssets(address[] memory assetAddresses) external override onlyOwner {
        _vault.resetAssets(assetAddresses);
    }

    function addStableCoins(address[] memory stableCoinAddresses) external override onlyOwner {
        _vault.addStableCoins(stableCoinAddresses);
    }

    function removeStableCoins(address[] memory stableCoinAddresses) external override onlyOwner {
        _vault.removeStableCoins(stableCoinAddresses);
    }

    function resetStableCoins(address[] memory stableCoinAddresses) external override onlyOwner {
        _vault.resetStableCoins(stableCoinAddresses);
    }

    function getAssets() external view override returns (address[] memory) {
        return _vault.getAssets();
    }

    function getStableCoins() external view override returns (address[] memory) {
        return _vault.getStableCoins();
    }

    function payReceiver(string memory name) external override {
        _vault.payReceiver(name);
    }

    // ============ View Interface ============

    function assetManager() external view returns (address) {
        return _assetManager.assetManager;
    }

    function wethAddress() external view returns (address) {
        return _vault.weth;
    }

    function whiteList() external view returns (IWhiteList) {
        return _assetManager.whiteList;
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
