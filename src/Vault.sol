// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IAssetManager, OnlyAssetManager} from "./interfaces/IAssetManager.sol";
import {IAMMProvider} from "provider-contracts/src/interfaces/IAMMProvider.sol";
import {IWhiteList} from "whitelist-contracts/src/interfaces/IWhiteList.sol";
import {IVault, ReceiverNotFound} from "./interfaces/IVault.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";
import {OnlyReceiver} from "./interfaces/IVault.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title Vault
 * @notice
 * @dev
 *
 * 1. ADMIN ROLE from hardware wallet, multi-sig would be better.
 * 2. ASSET MANAGER ROLE from hot wallet, browser extension wallet to be more convinient for use without losing any money.
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

    modifier onlyValidAsset(address assetAddress) {
        _vault.checkAsset(assetAddress);
        _;
    }

    function initialize(
        address whiteListAddress,
        address subscriptionAddress,
        address wethAddress_,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory ammProviders
    ) public initializer {
        _transferOwnership(tx.origin);
        _vault.initialize(wethAddress_, whiteListAddress, subscriptionAddress);
        _vault.addAssets(assetAddresses);
        _vault.addStableCoins(stableCoinAddresses);
        _assetManager.initialize(whiteListAddress);
        _assetManager.addLendingProviders(lendingProviders);
        _assetManager.addStakingProviders(stakingProviders);
        _assetManager.addAMMProviders(ammProviders);
    }

    // AMM functions

    function rebalance(
        address ammProvider,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external override onlyAssetManager onlyValidAsset(to) {
        _assetManager.rebalance(_vault, ammProvider, from, to, sellAmount, buyAmountMin, data);
    }

    function addLiquidity(address ammProvider, bytes memory data) external override onlyAssetManager {
        _assetManager.addLiquidity(ammProvider, data);
    }

    function removeLiquidity(address ammProvider, bytes memory data) external override onlyAssetManager {
        _assetManager.removeLiquidity(ammProvider, data);
    }

    function claimAMMFees(address ammProvider, bytes memory data) external override onlyAssetManager {
        _assetManager.claimAMMFees(ammProvider, data);
    }

    function getLiquidity(address ammProvider, bytes memory data) external view override returns (uint256) {
        return _assetManager.getLiquidity(ammProvider, data);
    }

    // Lending functions

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

    function getSuppliedBalance(address lendingProvider, address assetAddress)
        external
        view
        override
        returns (uint256)
    {
        return _assetManager.getSuppliedBalance(lendingProvider, assetAddress);
    }

    // Staking functions

    function stake(address stakingProvider, address asset, uint256 amount) external override onlyAssetManager {
        _assetManager.stake(stakingProvider, asset, amount);
    }

    function unstake(address stakingProvider, address asset, uint256 amount) external override onlyAssetManager {
        _assetManager.unstake(stakingProvider, asset, amount);
    }

    function getStakedBalance(address stakingProvider, address asset) external view override returns (uint256) {
        return _assetManager.getStakedBalance(stakingProvider, asset);
    }

    function getUnstakeRequestIds(address stakingProvider) external view override returns (uint256[] memory) {
        return _assetManager.getUnstakeRequestIds(stakingProvider);
    }

    function claimUnstaked(address stakingProvider, uint256[] memory requestIds) external override onlyAssetManager {
        _assetManager.claimUnstaked(stakingProvider, requestIds);
    }

    // IAssetManager interface

    function changeAssetManagerAddress(address newAssetManager) external override onlyAssetManager {
        _assetManager.setAssetManager(newAssetManager);
    }

    function setRebalanceConfig(address assetAddress, IAssetManager.RebalanceConfig memory _assetConfig)
        external
        override
        onlyOwner
    {
        _assetManager.setRebalanceConfig(assetAddress, _assetConfig);
    }

    function disableRebalanceUntilTimestamp(uint256 timestamp) external override onlyAssetManager {
        _assetManager.disableRebalanceUntilTimestamp(timestamp);
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

    function addAMMProviders(address[] memory ammProviderAddresses) external override onlyOwner {
        _assetManager.addAMMProviders(ammProviderAddresses);
    }

    function removeAMMProviders(address[] memory ammProviderAddresses) external override onlyOwner {
        _assetManager.removeAMMProviders(ammProviderAddresses);
    }

    function ETHToWETH(uint256 amount) external override onlyAssetManager {
        _vault.ETHToWETH(amount);
    }

    function WETHToETH(uint256 amount) external override onlyAssetManager {
        _vault.WETHToETH(amount);
    }

    // IVault Receiver interface

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

    /**
     * @notice Pay the receiver, would be triggered by anyone including AI agents.
     * @param name the name of the receiver.
     * @dev Trigger or anyone can execute it.
     */
    function payReceiver(string memory name) external override {
        _vault.payReceiver(name);
    }

    // IVault Owner interface

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

    function addStableCoins(address[] memory stableCoinAddresses) external override onlyOwner {
        _vault.addStableCoins(stableCoinAddresses);
    }

    function removeStableCoins(address[] memory stableCoinAddresses) external override onlyOwner {
        _vault.removeStableCoins(stableCoinAddresses);
    }

    // View functions

    function getAssets() external view override returns (address[] memory) {
        return _vault.getAssets();
    }

    function getStableCoins() external view override returns (address[] memory) {
        return _vault.getStableCoins();
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

    function getLendingProviders() external view override returns (address[] memory) {
        return _assetManager.getLendingProviders();
    }

    function getStakingProviders() external view override returns (address[] memory) {
        return _assetManager.getStakingProviders();
    }

    function getAMMProviders() external view override returns (address[] memory) {
        return _assetManager.getAMMProviders();
    }

    function lastRebalanceTimestamps(address assetAddress) external view returns (uint256) {
        return _assetManager.lastRebalanceTimestamps[assetAddress];
    }

    function rebalanceConfigs(address assetAddress) external view returns (IAssetManager.RebalanceConfig memory) {
        return _assetManager.rebalanceConfigs[assetAddress];
    }
}
