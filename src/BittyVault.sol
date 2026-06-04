// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IAssetManager} from "./interfaces/IAssetManager.sol";
import {IAMMProtocol} from "protocol-contracts/src/interfaces/IAMMProtocol.sol";
import {IGuard} from "guard-contracts/src/interfaces/IGuard.sol";
import {
    IVault,
    ReceiverNotFound,
    AddressZero,
    OnlyReceiver,
    OwnerAndAssetManagerMustDiffer
} from "./interfaces/IVault.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";

/**
 * @title BittyVault
 * @notice
 * @dev
 *
 * Role hierarchy:
 * - DEFAULT_ADMIN_ROLE: hardware wallet / multi-sig. Owns all config and irreversible ops.
 * - ASSET_MANAGER_ROLE: hot wallet / AI agent. Executes yield and trading operations only.
 */
contract BittyVault is IVault, IAssetManager, Initializable, AccessControl {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;

    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");

    string public vaultName;

    AssetManagerStorage internal _assetManager;
    VaultStorage internal _vault;

    receive() external payable {}

    function initialize(
        address owner_,
        string memory vaultName_,
        address assetManager_,
        address guardAddress,
        address wethAddress_,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols
    ) public initializer {
        if (assetManager_ == owner_) revert OwnerAndAssetManagerMustDiffer();
        vaultName = vaultName_;
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(ASSET_MANAGER_ROLE, assetManager_);
        _vault.initialize(guardAddress);
        _vault.addAssets(assetAddresses);
        _vault.addStableCoins(stableCoinAddresses);
        _assetManager.initialize(guardAddress, wethAddress_);
        _assetManager.addLendingProtocols(lendingProtocols);
        _assetManager.addStakingProtocols(stakingProtocols);
        _assetManager.addAMMProtocols(ammProtocols);
    }

    function _grantRole(bytes32 role, address account) internal override {
        if (role == ASSET_MANAGER_ROLE && hasRole(DEFAULT_ADMIN_ROLE, account)) {
            revert OwnerAndAssetManagerMustDiffer();
        }
        if (role == DEFAULT_ADMIN_ROLE && hasRole(ASSET_MANAGER_ROLE, account)) {
            revert OwnerAndAssetManagerMustDiffer();
        }
        super._grantRole(role, account);
    }

    function setName(string memory name) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        vaultName = name;
    }

    // ============ AMM ============

    function rebalance(
        address ammProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external override onlyRole(ASSET_MANAGER_ROLE) {
        _vault.checkAsset(from);
        _vault.checkAsset(to);
        _assetManager.rebalance(_vault, ammProtocol, from, to, sellAmount, buyAmountMin, data);
    }

    function addLiquidity(
        address ammProtocol,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external override onlyRole(ASSET_MANAGER_ROLE) {
        _assetManager.addLiquidity(ammProtocol, token0, amount0, token1, amount1, data);
    }

    function removeLiquidity(address ammProtocol, bytes memory data) external override onlyRole(ASSET_MANAGER_ROLE) {
        _assetManager.removeLiquidity(ammProtocol, data);
    }

    function claimAMMFees(address ammProtocol, bytes memory data) external override onlyRole(ASSET_MANAGER_ROLE) {
        _assetManager.claimAMMFees(ammProtocol, data);
    }

    function getLiquidity(address ammProtocol, bytes memory data) external view override returns (uint256) {
        return _assetManager.getLiquidity(ammProtocol, data);
    }

    // ============ Lending ============

    function supply(address lendingProtocol, address assetAddress, uint256 amount)
        external
        override
        onlyRole(ASSET_MANAGER_ROLE)
    {
        _assetManager.supply(lendingProtocol, assetAddress, amount);
    }

    function withdraw(address lendingProtocol, address assetAddress, uint256 amount)
        external
        override
        onlyRole(ASSET_MANAGER_ROLE)
    {
        _assetManager.withdraw(lendingProtocol, assetAddress, amount);
    }

    function getSuppliedBalance(address lendingProtocol, address assetAddress)
        external
        view
        override
        returns (uint256)
    {
        return _assetManager.getSuppliedBalance(lendingProtocol, assetAddress);
    }

    // ============ Staking ============

    function stake(address stakingProtocol, address asset, uint256 amount)
        external
        override
        onlyRole(ASSET_MANAGER_ROLE)
    {
        _assetManager.stake(stakingProtocol, asset, amount);
    }

    function unstake(address stakingProtocol, address asset, uint256 amount)
        external
        override
        onlyRole(ASSET_MANAGER_ROLE)
    {
        _assetManager.unstake(stakingProtocol, asset, amount);
    }

    function getStakedBalance(address stakingProtocol, address asset) external view override returns (uint256) {
        return _assetManager.getStakedBalance(stakingProtocol, asset);
    }

    function getUnstakeRequestIds(address stakingProtocol) external view override returns (uint256[] memory) {
        return _assetManager.getUnstakeRequestIds(stakingProtocol);
    }

    function claimUnstaked(address stakingProtocol, uint256[] memory requestIds)
        external
        override
        onlyRole(ASSET_MANAGER_ROLE)
    {
        _assetManager.claimUnstaked(stakingProtocol, requestIds);
    }

    // ============ Rebalance config ============

    function setRebalanceConfig(address assetAddress, IAssetManager.RebalanceConfig memory _assetConfig)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.setRebalanceConfig(assetAddress, _assetConfig);
    }

    function disableRebalanceUntilTimestamp(uint256 timestamp) external override onlyRole(ASSET_MANAGER_ROLE) {
        _assetManager.disableRebalanceUntilTimestamp(timestamp);
    }

    // ============ Protocol config ============

    function disableAddingProtocols() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.disableAddingProtocols();
        emit ProtocolsLocked();
    }

    function isAddingProtocolsDisabled() external view override returns (bool) {
        return _assetManager.addingProtocolsDisabled;
    }

    function addLendingProtocols(address[] memory lendingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addLendingProtocols(lendingProtocolAddresses);
    }

    function removeLendingProtocols(address[] memory lendingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.removeLendingProtocols(lendingProtocolAddresses);
    }

    function addStakingProtocols(address[] memory stakingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addStakingProtocols(stakingProtocolAddresses);
    }

    function removeStakingProtocols(address[] memory stakingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.removeStakingProtocols(stakingProtocolAddresses);
    }

    function addAMMProtocols(address[] memory ammProtocolAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.addAMMProtocols(ammProtocolAddresses);
    }

    function removeAMMProtocols(address[] memory ammProtocolAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.removeAMMProtocols(ammProtocolAddresses);
    }

    // ============ ETH/WETH ============

    function ETHToWETH(uint256 amount) external override onlyRole(ASSET_MANAGER_ROLE) {
        _assetManager.ETHToWETH(amount);
    }

    function WETHToETH(uint256 amount) external override onlyRole(ASSET_MANAGER_ROLE) {
        _assetManager.WETHToETH(amount);
    }

    // ============ Asset config ============

    function addAssets(address[] memory assetAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.addAssets(assetAddresses);
    }

    function removeAssets(address[] memory assetAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.removeAssets(assetAddresses);
    }

    function addStableCoins(address[] memory stableCoinAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.addStableCoins(stableCoinAddresses);
    }

    function removeStableCoins(address[] memory stableCoinAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.removeStableCoins(stableCoinAddresses);
    }

    // irreversible — DEFAULT_ADMIN_ROLE only
    function disableAddingAssets() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.disableAddingAssets();
        emit AssetsLocked();
    }

    function isAddingAssetsDisabled() external view override returns (bool) {
        return _vault.addingAssetsDisabled;
    }

    // ============ Receivers (RECEIVER_MANAGER_ROLE) ============

    function addReceiver(string memory name, IVault.Receiver calldata receiver_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.addReceiver(name, receiver_);
    }

    function updateReceiver(string memory name, IVault.Receiver calldata receiver_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.updateReceiver(name, receiver_);
    }

    function removeReceiver(string memory name) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.removeReceiver(name);
    }

    // DEFAULT_ADMIN_ROLE — controls the time-lock window for new receivers
    function setNewReceiverProtection(uint256 newReceiverProtection) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setNewReceiverProtection(newReceiverProtection);
    }

    function changeReceiverAddress(string memory name, address newReceiverAddress) external override {
        address oldReceiverAddress = _vault.getReceiverAddress(name);
        if (oldReceiverAddress == address(0)) revert ReceiverNotFound();
        if (oldReceiverAddress != msg.sender) revert OnlyReceiver();
        _vault.changeReceiverAddress(name, newReceiverAddress);
    }

    function payReceiver(string memory name) external override {
        _vault.payReceiver(name);
    }

    function payReceiverAmount(string memory name, uint256 amount) external override {
        _vault.payReceiverAmount(name, amount);
    }

    // ============ View ============

    function getAssets() external view override returns (address[] memory) {
        return _vault.getAssets();
    }

    function getStableCoins() external view override returns (address[] memory) {
        return _vault.getStableCoins();
    }

    function wethAddress() external view returns (address) {
        return _assetManager.weth;
    }

    function guard() external view returns (IGuard) {
        return _assetManager.guard;
    }

    function getLendingProtocols() external view override returns (address[] memory) {
        return _assetManager.getLendingProtocols();
    }

    function getStakingProtocols() external view override returns (address[] memory) {
        return _assetManager.getStakingProtocols();
    }

    function getAMMProtocols() external view override returns (address[] memory) {
        return _assetManager.getAMMProtocols();
    }

    function lastRebalanceTimestamps(address assetAddress) external view returns (uint256) {
        return _assetManager.lastRebalanceTimestamps[assetAddress];
    }

    function rebalanceConfigs(address assetAddress) external view returns (IAssetManager.RebalanceConfig memory) {
        return _assetManager.rebalanceConfigs[assetAddress];
    }
}
