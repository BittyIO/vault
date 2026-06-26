// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IAssetManager} from "./interfaces/IAssetManager.sol";
import {IGuard} from "guard-contracts/src/interfaces/IGuard.sol";
import {IVault, ReceiverNotFound, OnlyReceiver, OwnerAndAssetManagerMustDiffer} from "./interfaces/IVault.sol";
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
        address owner,
        string memory initialName,
        address[] memory assetManagers,
        address guardAddress,
        address weth,
        address[] memory assetAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols
    ) public initializer {
        vaultName = initialName;
        _grantRole(DEFAULT_ADMIN_ROLE, owner);

        for (uint256 i = 0; i < assetManagers.length; i++) {
            if (assetManagers[i] == owner) revert OwnerAndAssetManagerMustDiffer();
            if (assetManagers[i] != address(0)) {
                _grantRole(ASSET_MANAGER_ROLE, assetManagers[i]);
            }
        }

        _vault.initialize(guardAddress);
        if (assetAddresses.length > 0) {
            _vault.addAssets(assetAddresses);
        }

        _assetManager.initialize(guardAddress, weth);
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

    function _grantRole(bytes32 role, address account) internal override {
        if (role == ASSET_MANAGER_ROLE && hasRole(DEFAULT_ADMIN_ROLE, account)) {
            revert OwnerAndAssetManagerMustDiffer();
        }
        if (role == DEFAULT_ADMIN_ROLE && hasRole(ASSET_MANAGER_ROLE, account)) {
            revert OwnerAndAssetManagerMustDiffer();
        }
        super._grantRole(role, account);
    }

    function setName(string memory newName) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        vaultName = newName;
    }

    // ============ AMM ============

    function marketSell(
        address ammProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external override onlyRole(ASSET_MANAGER_ROLE) {
        _vault.checkAsset(from);
        _vault.checkAsset(to);
        _assetManager.marketSell(_vault, ammProtocol, from, to, sellAmount, buyAmountMin, data);
    }

    function marketBuy(
        address ammProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        bytes memory data
    ) external override onlyRole(ASSET_MANAGER_ROLE) {
        _vault.checkAsset(from);
        _vault.checkAsset(to);
        _assetManager.marketBuy(_vault, ammProtocol, from, to, buyAmount, sellAmountMax, data);
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

    // ============ Intent ============

    function limitSell(
        address intentProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        uint32 validTo
    ) external override onlyRole(ASSET_MANAGER_ROLE) returns (bytes32 orderId) {
        _vault.checkAsset(from);
        _vault.checkAsset(to);
        return _assetManager.limitSell(_vault, intentProtocol, from, to, sellAmount, buyAmountMin, validTo);
    }

    function limitBuy(
        address intentProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        uint32 validTo
    ) external override onlyRole(ASSET_MANAGER_ROLE) returns (bytes32 orderId) {
        _vault.checkAsset(from);
        _vault.checkAsset(to);
        return _assetManager.limitBuy(_vault, intentProtocol, from, to, buyAmount, sellAmountMax, validTo);
    }

    function cancelLimitOrder(address intentProtocol, bytes memory data)
        external
        override
        onlyRole(ASSET_MANAGER_ROLE)
    {
        _assetManager.cancelLimitOrder(intentProtocol, data);
    }

    function cleanExpiredOrders(address intentProtocol, bytes32[] calldata orderDigests) external override {
        _assetManager.cleanExpiredOrders(intentProtocol, orderDigests);
    }

    function twapSell(
        address intentProtocol,
        address from,
        address to,
        uint256 totalSellAmount,
        uint256 minPartLimit,
        uint256 n,
        uint256 partDuration,
        uint256 span
    ) external override onlyRole(ASSET_MANAGER_ROLE) returns (bytes32 twapId) {
        _vault.checkAsset(from);
        _vault.checkAsset(to);
        return
            _assetManager.twapSell(
                _vault, intentProtocol, from, to, totalSellAmount, minPartLimit, n, partDuration, span
            );
    }

    function cancelTwap(address intentProtocol, bytes32 twapId) external override onlyRole(ASSET_MANAGER_ROLE) {
        _assetManager.cancelTwap(intentProtocol, twapId);
    }

    function twapBuy(
        address intentProtocol,
        address from,
        address to,
        uint256 totalBuyAmount,
        uint256 sellAmountPerPart,
        uint256 n,
        uint256 partDuration,
        uint256 span
    ) external override onlyRole(ASSET_MANAGER_ROLE) returns (bytes32 twapId) {
        _vault.checkAsset(from);
        _vault.checkAsset(to);
        return _assetManager.twapBuy(
            _vault, intentProtocol, from, to, totalBuyAmount, sellAmountPerPart, n, partDuration, span
        );
    }

    function getIntentProtocols() external view override returns (address[] memory) {
        return _assetManager.getIntentProtocols();
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

    function setMinimalBalance(address assetAddress, uint256 newMinimalBalance)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.setMinimalBalance(assetAddress, newMinimalBalance);
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

    function addIntentProtocols(address[] memory intentProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addIntentProtocols(intentProtocolAddresses);
    }

    function removeIntentProtocols(address[] memory intentProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.removeIntentProtocols(intentProtocolAddresses);
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

    // irreversible — DEFAULT_ADMIN_ROLE only
    function disableAddingAssets() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.disableAddingAssets();
        emit AssetsLocked();
    }

    function isAddingAssetsDisabled() external view override returns (bool) {
        return _vault.addingAssetsDisabled;
    }

    // ============ Receivers (RECEIVER_MANAGER_ROLE) ============

    function addReceiver(string memory receiverName, IVault.Receiver calldata receiver_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.addReceiver(receiverName, receiver_);
    }

    function updateReceiver(string memory receiverName, IVault.Receiver calldata receiver_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.updateReceiver(receiverName, receiver_);
    }

    function removeReceiver(string memory receiverName) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.removeReceiver(receiverName);
    }

    // DEFAULT_ADMIN_ROLE — controls the time-lock window for new receivers
    function setNewReceiverProtection(uint256 newReceiverProtection) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setNewReceiverProtection(newReceiverProtection);
    }

    function changeReceiverAddress(string memory receiverName, address newReceiverAddress) external override {
        address oldReceiverAddress = _vault.getReceiverAddress(receiverName);
        if (oldReceiverAddress == address(0)) revert ReceiverNotFound();
        if (oldReceiverAddress != msg.sender) revert OnlyReceiver();
        _vault.changeReceiverAddress(receiverName, newReceiverAddress);
    }

    function payReceiver(string memory receiverName) external override {
        _vault.payReceiver(receiverName);
    }

    function payReceiverAmount(string memory receiverName, uint256 amount) external override {
        _vault.payReceiverAmount(receiverName, amount);
    }

    // ============ View ============

    function name() external view override returns (string memory) {
        return vaultName;
    }

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

    function minimalBalance(address assetAddress) external view returns (uint256) {
        return _assetManager.minimalBalances[assetAddress];
    }
}
