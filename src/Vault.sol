// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IAssetManager, OnlyAssetManager, InvalidIntentProvider} from "./interfaces/IAssetManager.sol";
import {IAMMProvider} from "./interfaces/IAMMProvider.sol";
import {IWhiteList} from "whitelist-contracts/src/interfaces/IWhiteList.sol";
import {IVault, ReceiverNotFound} from "./interfaces/IVault.sol";
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
        address[] memory ammProviders,
        address[] memory intentProviders_
    ) public initializer {
        _transferOwnership(tx.origin);
        _vault.initialize(wethAddress_, whiteListAddress, subscriptionAddress);
        _vault.addAssets(assetAddresses);
        _vault.addStableCoins(stableCoinAddresses);
        _assetManager.initialize(whiteListAddress);
        _assetManager.addLendingProviders(lendingProviders);
        _assetManager.addStakingProviders(stakingProviders);
        _assetManager.addAMMProviders(ammProviders);
        _assetManager.addIntentProviders(intentProviders_);
    }

    // ============ IAssetManager Interface ============

    function changeAssetManagerAddress(address newAssetManager) external override onlyAssetManager {
        _assetManager.setAssetManager(newAssetManager);
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

    function getIntentProviders() external view override returns (address[] memory) {
        return _assetManager.getIntentProviders();
    }

    function setRebalanceConfig(address assetAddress, IAssetManager.RebalanceConfig memory _assetConfig)
        external
        override
        onlyOwner
    {
        _assetManager.setRebalanceConfig(assetAddress, _assetConfig);
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

    function stake(address stakingProvider, address asset, uint256 amount) external override onlyAssetManager {
        _assetManager.stake(stakingProvider, asset, amount);
    }

    function unstake(address stakingProvider, address asset, uint256 amount) external override onlyAssetManager {
        _assetManager.unstake(stakingProvider, asset, amount);
    }

    function getStakingBalance(address stakingProvider, address asset) external view override returns (uint256) {
        return _assetManager.getStakingBalance(stakingProvider, asset);
    }

    function getUnstakeRequestIds(address stakingProvider) external view override returns (uint256[] memory) {
        return _assetManager.getUnstakeRequestIds(stakingProvider);
    }

    function claim(address stakingProvider, uint256[] memory requestIds) external override onlyAssetManager {
        _assetManager.claim(stakingProvider, requestIds);
    }

    function ammRebalance(
        address ammProvider,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external override onlyAssetManager onlyValidAsset(to) {
        _assetManager.ammRebalance(_vault, ammProvider, from, to, sellAmount, buyAmountMin, data);
    }

    function intentRebalance(
        address intentProvider,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        uint32 validTo,
        bool isSellOrder
    ) external override onlyAssetManager onlyValidAsset(to) {
        _assetManager.intentRebalance(_vault, intentProvider, from, to, sellAmount, buyAmountMin, validTo, isSellOrder);
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

    function addAMMProviders(address[] memory ammProviderAddresses) external override onlyOwner {
        _assetManager.addAMMProviders(ammProviderAddresses);
    }

    function removeAMMProviders(address[] memory ammProviderAddresses) external override onlyOwner {
        _assetManager.removeAMMProviders(ammProviderAddresses);
    }

    function addIntentProviders(address[] memory intentProviderAddresses) external override onlyOwner {
        _assetManager.addIntentProviders(intentProviderAddresses);
    }

    function removeIntentProviders(address[] memory intentProviderAddresses) external override onlyOwner {
        _assetManager.removeIntentProviders(intentProviderAddresses);
    }

    function cancelIntentRebalance(address intentProvider, bytes memory data) external override onlyAssetManager {
        _assetManager.cancelIntentRebalance(intentProvider, data);
    }

    function revokeIntentProviderApprovals(address intentProvider, address[] calldata tokens)
        external
        override
        onlyAssetManager
    {
        _assetManager.revokeIntentProviderApprovals(intentProvider, tokens);
    }

    function cleanExpiredIntentOrders(address intentProvider, bytes32[] calldata orderDigests) external override {
        _assetManager.cleanExpiredIntentOrders(intentProvider, orderDigests);
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

    function addStableCoins(address[] memory stableCoinAddresses) external override onlyOwner {
        _vault.addStableCoins(stableCoinAddresses);
    }

    function removeStableCoins(address[] memory stableCoinAddresses) external override onlyOwner {
        _vault.removeStableCoins(stableCoinAddresses);
    }

    function getAssets() external view override returns (address[] memory) {
        return _vault.getAssets();
    }

    function getStableCoins() external view override returns (address[] memory) {
        return _vault.getStableCoins();
    }

    /**
     * @notice Pay the receiver, would be triggered by anyone including AI agents.
     * @param name the name of the receiver.
     * @dev Trigger or anyone can execute it.
     */
    function payReceiver(string memory name) external override {
        _vault.payReceiver(name);
    }

    function addLiquidity(address ammProvider, bytes memory data) external payable override onlyAssetManager {
        address clone = _assetManager.getOrCloneAMMProvider(ammProvider);
        IAMMProvider(clone).addLiquidity{value: msg.value}(data);
    }

    function removeLiquidity(address ammProvider, bytes memory data) external payable override onlyAssetManager {
        address clone = _assetManager.getOrCloneAMMProvider(ammProvider);
        IAMMProvider(clone).removeLiquidity{value: msg.value}(data);
    }

    function claimFees(address ammProvider, bytes memory data) external payable override onlyAssetManager {
        address clone = _assetManager.getOrCloneAMMProvider(ammProvider);
        IAMMProvider(clone).claimFees{value: msg.value}(data);
    }

    function getLiquidity(address ammProvider, bytes memory data) external view override returns (uint256) {
        return _assetManager.getLiquidity(ammProvider, data);
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

    function lastRebalanceTimestamps(address assetAddress) external view returns (uint256) {
        return _assetManager.lastRebalanceTimestamps[assetAddress];
    }

    function rebalanceConfigs(address assetAddress) external view returns (IAssetManager.RebalanceConfig memory) {
        return _assetManager.rebalanceConfigs[assetAddress];
    }
}
