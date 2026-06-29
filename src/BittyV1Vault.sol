// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AccessControlDefaultAdminRulesUpgradeable
} from "openzeppelin-contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {IBittyV1AssetManager} from "./interfaces/IBittyV1AssetManager.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {
    IBittyV1Vault,
    ReceiverNotFound,
    OnlyReceiver,
    OwnerAndAssetManagerMustDiffer,
    AddressZero
} from "./interfaces/IBittyV1Vault.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";
import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {IERC1271} from "openzeppelin-contracts/contracts/interfaces/IERC1271.sol";

/**
 * @title BittyV1Vault
 * @notice
 * @dev
 *
 * Role hierarchy:
 * - DEFAULT_ADMIN_ROLE: hardware wallet / multi-sig. Owns all config and irreversible ops.
 *   Managed via {AccessControlDefaultAdminRulesUpgradeable} (2-step transfer + delay).
 * - ASSET_MANAGER_ROLE: hot wallet / AI agent. Executes yield and trading operations only.
 */
contract BittyV1Vault is IBittyV1Vault, IBittyV1AssetManager, AccessControlDefaultAdminRulesUpgradeable {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;

    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");
    uint48 public constant OWNER_TRANSFER_DELAY = 1 days;

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
        if (owner == address(0)) revert AddressZero();
        vaultName = initialName;
        __AccessControl_init();
        __AccessControlDefaultAdminRules_init(OWNER_TRANSFER_DELAY, owner);

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

    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        if (role == ASSET_MANAGER_ROLE && account == defaultAdmin()) {
            revert OwnerAndAssetManagerMustDiffer();
        }
        return super._grantRole(role, account);
    }

    function beginDefaultAdminTransfer(address newAdmin) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin != address(0) && hasRole(ASSET_MANAGER_ROLE, newAdmin)) {
            revert OwnerAndAssetManagerMustDiffer();
        }
        super.beginDefaultAdminTransfer(newAdmin);
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

    function getClone(address intentProtocol) external view returns (address) {
        return _assetManager.getClone(intentProtocol);
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

    function addReceiver(string memory receiverName, IBittyV1Vault.Receiver calldata receiver_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.addReceiver(receiverName, receiver_);
    }

    function updateReceiver(string memory receiverName, IBittyV1Vault.Receiver calldata receiver_)
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

    function guard() external view returns (IBittyV1Guard) {
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

    // ============ EIP-1271 (intent order signature validation) ============

    /**
     * @notice Declares ERC-1271 support so composableCow uses the non-Safe ERC-1271 signature
     *         path in getTradeableOrderWithSignature instead of the Gnosis Safe module path.
     */
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC1271).interfaceId // 0x1626ba7e
            || super.supportsInterface(interfaceId);
    }

    /**
     * @notice Validates intent order signatures on behalf of the vault.
     *         Iterates all registered intent protocol clones and delegates to each one's
     *         isValidSignature() until a match is found. Works for any protocol
     *         (CoW Swap, UniswapX, etc.) without protocol-specific vault logic.
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        address[] memory protocols = _assetManager.getIntentProtocols();
        for (uint256 i = 0; i < protocols.length; i++) {
            address clone = _assetManager.clonedProtocols[protocols[i]];
            if (clone == address(0)) continue;
            try IBittyV1IntentProtocol(clone).isValidSignature(hash, signature) returns (bytes4 result) {
                if (result == 0x1626ba7e) return result;
            } catch {}
        }
        return 0xffffffff;
    }
}
