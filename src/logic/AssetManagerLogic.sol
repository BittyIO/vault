// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IBittyV1Guard, NotRegistered, Deprecated} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {IBittyV1AMMProtocol} from "protocol-contracts/src/interfaces/IBittyV1AMMProtocol.sol";
import {IBittyV1LendingProtocol} from "protocol-contracts/src/interfaces/IBittyV1LendingProtocol.sol";
import {IBittyV1StakingProtocol} from "protocol-contracts/src/interfaces/IBittyV1StakingProtocol.sol";
import {
    InvalidLendingProtocol,
    InvalidStakingProtocol,
    DisableRebalanceUntilTimestampTooEarly,
    DisableRebalanceUntilTimestampTooLong,
    InvalidAMMProtocol,
    InvalidIntentProtocol
} from "../interfaces/IBittyV1AssetManager.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {
    AddressZero,
    AmountIsZero,
    InsufficientBalance,
    NotInitialized,
    AlreadyInitialized,
    AddingProtocolsDisabled,
    AutoYieldRoute
} from "../interfaces/IBittyV1Vault.sol";
import {AssetManagerStorage, AutoYieldConfig, VaultStorage} from "./Storages.sol";
import {VaultLogic} from "./VaultLogic.sol";

/**
 * @dev Minimal view into an intent protocol's settlement addresses: the relayer (e.g. CoW's
 *      vaultRelayer), which a gasless off-chain order's sell token is approved to so it can be
 *      pulled at settlement, and the settlement contract itself, on which the vault invalidates an
 *      order to cancel it.
 */
interface IIntentRelayerSource {
    function vaultRelayer() external view returns (address);
    function settlement() external view returns (address);
}

/**
 * @dev The order-cancellation entrypoint on CoW's GPv2Settlement. Only the order owner (the vault,
 *      encoded in `orderUid`) may call it; it marks the order fully filled so no solver can settle
 *      it and emits OrderInvalidated, which the orderbook indexes as cancelled.
 */
interface IIntentSettlement {
    function invalidateOrder(bytes calldata orderUid) external;
}

/**
 * @title AssetManagerLogic
 * @notice The asset manager's full surface: yield (lending / staking / auto-yield), trading (AMM
 *         liquidity and intent limit/TWAP orders), config, and protocol registration. Operates on
 *         {AssetManagerStorage}.
 */
library AssetManagerLogic {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Clones for address;
    using Address for address;

    uint256 constant REBALANCE_DISABLE_MAX_DURATION = 4 * 365 days;

    modifier onlyInitialized(AssetManagerStorage storage logicStorage) {
        if (!logicStorage.isInitialized) {
            revert NotInitialized();
        }
        _;
    }

    modifier onlyNotInitialized(AssetManagerStorage storage logicStorage) {
        if (logicStorage.isInitialized) {
            revert AlreadyInitialized();
        }
        _;
    }

    modifier onlyAddingProtocolsEnabled(AssetManagerStorage storage logicStorage) {
        if (logicStorage.addingProtocolsDisabled) {
            revert AddingProtocolsDisabled();
        }
        _;
    }

    function initialize(AssetManagerStorage storage logicStorage, address guardAddress)
        external
        onlyNotInitialized(logicStorage)
    {
        if (guardAddress == address(0)) {
            revert AddressZero();
        }
        logicStorage.guard = IBittyV1Guard(guardAddress);
        logicStorage.isInitialized = true;
    }

    function getClone(AssetManagerStorage storage logicStorage, address protocol) external view returns (address) {
        return logicStorage.clonedProtocols[protocol];
    }

    function setMinimalBalance(AssetManagerStorage storage logicStorage, address assetAddress, uint256 minimalBalance)
        external
        onlyInitialized(logicStorage)
    {
        if (assetAddress == address(0)) revert AddressZero();
        logicStorage.minimalBalances[assetAddress] = minimalBalance;
    }

    /**
     * @notice Set the vault's single asset manager, replacing any previous one. The manager has full
     * trading access, bounded only by the token allowlist and per-asset minimal-balance floors.
     */
    function setAssetManager(AssetManagerStorage storage logicStorage, address assetManager)
        external
        onlyInitialized(logicStorage)
    {
        if (assetManager == address(0)) revert AddressZero();
        logicStorage.assetManager = assetManager;
    }

    function removeAssetManager(AssetManagerStorage storage logicStorage) external onlyInitialized(logicStorage) {
        logicStorage.assetManager = address(0);
    }

    // ============ Lending ============

    function supply(
        AssetManagerStorage storage logicStorage,
        address lendingProtocol,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        _supply(logicStorage, lendingProtocol, assetAddress, amount);
    }

    // Shared by supply and autoYield: full validation + execution against the REGISTERED protocol
    // address (cloned on first use).
    function _supply(
        AssetManagerStorage storage logicStorage,
        address lendingProtocol,
        address assetAddress,
        uint256 amount
    ) private {
        if (!logicStorage.lendingProtocols.contains(lendingProtocol)) {
            revert InvalidLendingProtocol();
        }
        if (logicStorage.guard.isLendingProtocolDeprecated(lendingProtocol)) {
            revert Deprecated();
        }
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        lendingProtocol = _cloneProtocol(logicStorage, lendingProtocol);
        if (IERC20(assetAddress).allowance(address(this), lendingProtocol) < amount) {
            IERC20(assetAddress).forceApprove(lendingProtocol, type(uint256).max);
        }
        IBittyV1LendingProtocol(lendingProtocol).supply(assetAddress, amount);
    }

    /**
     * @notice Withdraw a supplied asset, delivered to `recipient`.
     * @dev Pass the vault as `recipient` for a normal withdrawal, or a configured scheduledPayment for an
     * on-behalf payment so the asset is delivered directly in a single step. The caller (the vault
     * facade) is responsible for restricting `recipient` to the vault or a configured scheduledPayment.
     * @return delivered The amount of `assetAddress` delivered to `recipient`.
     */
    function withdraw(
        AssetManagerStorage storage logicStorage,
        address lendingProtocol,
        address assetAddress,
        uint256 amount,
        address recipient
    ) external onlyInitialized(logicStorage) returns (uint256 delivered) {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        lendingProtocol = logicStorage.clonedProtocols[lendingProtocol];
        if (lendingProtocol == address(0)) {
            revert InvalidLendingProtocol();
        }
        if (amount != type(uint256).max) {
            uint256 supplyAmount = IBittyV1LendingProtocol(lendingProtocol).getSuppliedBalance(assetAddress);
            if (supplyAmount < amount) {
                revert InsufficientBalance();
            }
        }
        _approveReceiptToken(lendingProtocol, assetAddress);
        return IBittyV1LendingProtocol(lendingProtocol).withdraw(assetAddress, amount, recipient);
    }

    function getSuppliedBalance(AssetManagerStorage storage logicStorage, address lendingProtocol, address assetAddress)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256)
    {
        address _clonedProtocol = logicStorage.clonedProtocols[lendingProtocol];
        if (_clonedProtocol == address(0)) {
            return 0;
        }
        return IBittyV1LendingProtocol(_clonedProtocol).getSuppliedBalance(assetAddress);
    }

    // ============ Staking ============

    function stake(
        AssetManagerStorage storage logicStorage,
        address stakingProtocol,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        _stake(logicStorage, stakingProtocol, assetAddress, amount);
    }

    // Shared by stake and autoYield: full validation + execution against the REGISTERED protocol
    // address (cloned on first use).
    function _stake(
        AssetManagerStorage storage logicStorage,
        address stakingProtocol,
        address assetAddress,
        uint256 amount
    ) private {
        if (!logicStorage.stakingProtocols.contains(stakingProtocol)) {
            revert InvalidStakingProtocol();
        }
        if (logicStorage.guard.isStakingProtocolDeprecated(stakingProtocol)) {
            revert Deprecated();
        }
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        stakingProtocol = _cloneProtocol(logicStorage, stakingProtocol);
        if (IERC20(assetAddress).allowance(address(this), stakingProtocol) < amount) {
            IERC20(assetAddress).forceApprove(stakingProtocol, type(uint256).max);
        }
        IBittyV1StakingProtocol(stakingProtocol).stake(assetAddress, amount);
    }

    /**
     * @notice Unstake a staked asset, delivered to `recipient`.
     * @dev Pass the vault as `recipient` for a normal unstake, or a configured scheduledPayment for an
     * on-behalf payment so the asset is delivered directly in a single step. The caller (the vault
     * facade) is responsible for restricting `recipient` to the vault or a configured scheduledPayment.
     * Reverts for staking protocols that settle asynchronously when `recipient` is not the vault.
     * @return delivered The amount of `assetAddress` delivered to `recipient`.
     */
    function unstake(
        AssetManagerStorage storage logicStorage,
        address stakingProtocol,
        address assetAddress,
        uint256 amount,
        address recipient
    ) external onlyInitialized(logicStorage) returns (uint256 delivered) {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        stakingProtocol = logicStorage.clonedProtocols[stakingProtocol];
        if (stakingProtocol == address(0)) {
            revert InvalidStakingProtocol();
        }
        if (amount != type(uint256).max) {
            uint256 stakingBalance = IBittyV1StakingProtocol(stakingProtocol).getStakedBalance(assetAddress);
            if (stakingBalance < amount) {
                revert InsufficientBalance();
            }
        }
        _approveReceiptToken(stakingProtocol, assetAddress);
        return IBittyV1StakingProtocol(stakingProtocol).unstake(assetAddress, amount, recipient);
    }

    function getStakedBalance(AssetManagerStorage storage logicStorage, address stakingProtocol, address assetAddress)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256)
    {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        address _clonedProtocol = logicStorage.clonedProtocols[stakingProtocol];
        if (_clonedProtocol == address(0)) {
            return 0;
        }
        return IBittyV1StakingProtocol(_clonedProtocol).getStakedBalance(assetAddress);
    }

    function getUnstakeRequestIds(AssetManagerStorage storage logicStorage, address stakingProtocol)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256[] memory)
    {
        address _clonedProtocol = logicStorage.clonedProtocols[stakingProtocol];
        if (_clonedProtocol == address(0)) {
            return new uint256[](0);
        }
        return IBittyV1StakingProtocol(_clonedProtocol).getUnstakeRequestIds();
    }

    function claimUnstaked(
        AssetManagerStorage storage logicStorage,
        address stakingProtocol,
        uint256[] memory requestIds
    ) external onlyInitialized(logicStorage) {
        if (requestIds.length == 0) {
            return;
        }
        stakingProtocol = logicStorage.clonedProtocols[stakingProtocol];
        if (stakingProtocol == address(0)) {
            revert InvalidStakingProtocol();
        }
        IBittyV1StakingProtocol(stakingProtocol).claimUnstaked(requestIds);
    }

    // ============ Auto yield ============

    /**
     * @notice Set (or clear, protocol = address(0)) the default yield route for `assetAddress`.
     * @dev The protocol must already be registered on the vault for the chosen protocolType — autoYield can
     * never route funds anywhere the owner hasn't enabled. Re-validated again at execution time, so a
     * later protocol removal or deprecation disables the route rather than bypassing the check.
     */
    function setAutoYielding(
        AssetManagerStorage storage logicStorage,
        address assetAddress,
        address protocol,
        bool isSupplying
    ) external onlyInitialized(logicStorage) {
        _setAutoYielding(logicStorage, assetAddress, protocol, isSupplying);
    }

    /**
     * @dev Register an asset and yield protocol on the vault and set its default route. Used at
     *      initialization when routes may declare assets/protocols beyond the activation arrays.
     */
    function registerAutoYieldRoute(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        AutoYieldRoute memory route
    ) external onlyInitialized(logicStorage) {
        if (route.protocol == address(0)) revert AddressZero();
        VaultLogic.addAsset(vaultStorage, route.asset);
        _addProtocol(logicStorage, route.protocol, route.isSupplying ? ProtocolType.Lending : ProtocolType.Staking);
        _setAutoYielding(logicStorage, route.asset, route.protocol, route.isSupplying);
    }

    function _setAutoYielding(
        AssetManagerStorage storage logicStorage,
        address assetAddress,
        address protocol,
        bool isSupplying
    ) private {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (protocol == address(0)) {
            delete logicStorage.autoYieldConfigs[assetAddress];
            return;
        }
        if (isSupplying) {
            if (!logicStorage.lendingProtocols.contains(protocol)) {
                revert InvalidLendingProtocol();
            }
        } else {
            if (!logicStorage.stakingProtocols.contains(protocol)) {
                revert InvalidStakingProtocol();
            }
        }
        logicStorage.autoYieldConfigs[assetAddress] = AutoYieldConfig({protocol: protocol, isSupplying: isSupplying});
    }

    function getAutoYielding(AssetManagerStorage storage logicStorage, address assetAddress)
        external
        view
        returns (address protocol, bool isSupplying)
    {
        AutoYieldConfig storage cfg = logicStorage.autoYieldConfigs[assetAddress];
        return (cfg.protocol, cfg.isSupplying);
    }

    /**
     * @notice Sweep the vault's spendable wallet balance of `assetAddress` into its configured
     * default yield route (supply or stake). Best-effort: a no-op (returns 0) when no route is
     * configured or nothing is spendable, so the vault's {receive} can call it on every deposit
     * without ever reverting. Not exposed as a standalone entry point — routing funds on demand must
     * not be triggerable by third parties (a griefer could otherwise strand the asset manager's
     * swap liquidity in a protocol).
     * @dev Spendable excludes tokens reserved by open intent orders (they must stay liquid to settle)
     * and the asset's minimalBalance, which doubles as the owner's liquid buffer for payments.
     * @return amount The amount supplied/staked.
     */
    function autoYield(AssetManagerStorage storage logicStorage, address assetAddress)
        external
        onlyInitialized(logicStorage)
        returns (uint256 amount)
    {
        AutoYieldConfig memory cfg = logicStorage.autoYieldConfigs[assetAddress];
        if (cfg.protocol == address(0)) {
            return 0;
        }
        uint256 balance = _addressBalance(assetAddress);
        uint256 reserved = logicStorage.minimalBalances[assetAddress];
        amount = balance > reserved ? balance - reserved : 0;
        if (amount == 0) {
            return 0;
        }
        if (cfg.isSupplying) {
            _supply(logicStorage, cfg.protocol, assetAddress, amount);
        } else {
            _stake(logicStorage, cfg.protocol, assetAddress, amount);
        }
    }

    // ============ AMM liquidity ============

    function addLiquidity(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address ammProtocol,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external onlyInitialized(logicStorage) {
        _checkAMMProtocol(logicStorage, ammProtocol);
        if (logicStorage.guard.isAMMProtocolDeprecated(ammProtocol)) revert Deprecated();

        VaultLogic.checkAsset(vaultStorage, token0);
        VaultLogic.checkAsset(vaultStorage, token1);

        address clone = _cloneProtocol(logicStorage, ammProtocol);
        if (token0 != address(0) && amount0 > 0 && IERC20(token0).allowance(address(this), clone) < amount0) {
            IERC20(token0).forceApprove(clone, type(uint256).max);
        }
        if (token1 != address(0) && amount1 > 0 && IERC20(token1).allowance(address(this), clone) < amount1) {
            IERC20(token1).forceApprove(clone, type(uint256).max);
        }

        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).addLiquidity(data);
    }

    function removeLiquidity(AssetManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) revert InvalidAMMProtocol();
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).removeLiquidity(data);
    }

    function decreaseLiquidity(AssetManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) revert InvalidAMMProtocol();
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).decreaseLiquidity(data);
    }

    function claimAMMFees(AssetManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) revert InvalidAMMProtocol();
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).claimAMMFees(data);
    }

    function getLiquidity(AssetManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        view
        returns (uint256)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) return 0;
        return IBittyV1AMMProtocol(clone).getLiquidity(data);
    }

    function disableRebalanceUntilTimestamp(AssetManagerStorage storage logicStorage, uint256 timestamp)
        external
        onlyInitialized(logicStorage)
    {
        if (timestamp == 0) {
            return;
        }
        if (timestamp < logicStorage.rebalanceDisabledUntilTimestamp) {
            revert DisableRebalanceUntilTimestampTooEarly();
        }
        if (timestamp > block.timestamp + REBALANCE_DISABLE_MAX_DURATION) {
            revert DisableRebalanceUntilTimestampTooLong();
        }
        logicStorage.rebalanceDisabledUntilTimestamp = uint64(timestamp);
    }

    // ============ Intent protocols (limit + TWAP) ============

    /**
     * @notice Grant `intentProtocol`'s settlement relayer a max allowance of `token`. Gasless
     *         off-chain-signed orders do no on-chain placement tx, so — unlike {limitSell}/{limitBuy},
     *         which approve the exact sell amount per order — the relayer must be pre-approved once per
     *         sell token for settlement to pull it. Reads the relayer from the registered protocol so a
     *         caller can't approve an arbitrary spender.
     */
    function approveIntentRelayer(AssetManagerStorage storage logicStorage, address intentProtocol, address token)
        external
    {
        _checkIntentProtocol(logicStorage, intentProtocol);
        address relayer = IIntentRelayerSource(intentProtocol).vaultRelayer();
        IERC20(token).forceApprove(relayer, type(uint256).max);
    }

    /**
     * @notice Cancel one or more gasless off-chain orders by invalidating them on-chain. CoW's API only
     *         accepts ECDSA-signed cancellations from an EOA owner, so a vault (eip1271) order can't be
     *         soft-cancelled off-chain — the owner must invalidate it on the settlement contract. Each
     *         `orderUid` encodes this vault as the owner, so GPv2Settlement.invalidateOrder accepts the
     *         call (msg.sender == owner) and no solver can settle the order afterwards. Batched so a TWAP
     *         (many part orders) is cancelled in one tx. Reads the settlement from the registered protocol
     *         so a caller can't target an arbitrary contract.
     */
    function cancelIntentOrders(
        AssetManagerStorage storage logicStorage,
        address intentProtocol,
        bytes[] calldata orderUids
    ) external {
        _checkIntentProtocol(logicStorage, intentProtocol);
        IIntentSettlement settlement = IIntentSettlement(IIntentRelayerSource(intentProtocol).settlement());
        for (uint256 i = 0; i < orderUids.length; i++) {
            settlement.invalidateOrder(orderUids[i]);
        }
    }

    // ============ Protocol registration ============

    function disableAddingProtocols(AssetManagerStorage storage logicStorage) external onlyInitialized(logicStorage) {
        logicStorage.addingProtocolsDisabled = true;
    }

    // Which protocol registry an add/remove targets. Lets the four protocol protocolTypes share one
    // add/remove implementation instead of repeating the loop + guard check four times each.
    enum ProtocolType {
        Lending,
        Staking,
        AMM,
        Intent
    }

    function _protocolSet(AssetManagerStorage storage logicStorage, ProtocolType protocolType)
        private
        view
        returns (EnumerableSet.AddressSet storage)
    {
        if (protocolType == ProtocolType.Lending) return logicStorage.lendingProtocols;
        if (protocolType == ProtocolType.Staking) return logicStorage.stakingProtocols;
        if (protocolType == ProtocolType.AMM) return logicStorage.ammProtocols;
        return logicStorage.intentProtocols;
    }

    function _isProtocolRegistered(IBittyV1Guard guard, address protocol, ProtocolType protocolType)
        private
        view
        returns (bool)
    {
        if (protocolType == ProtocolType.Lending) return guard.isLendingProtocolRegistered(protocol);
        if (protocolType == ProtocolType.Staking) return guard.isStakingProtocolRegistered(protocol);
        if (protocolType == ProtocolType.AMM) return guard.isAMMProtocolRegistered(protocol);
        return guard.isIntentProtocolRegistered(protocol);
    }

    function _addProtocols(
        AssetManagerStorage storage logicStorage,
        address[] memory protocols,
        ProtocolType protocolType
    ) private {
        for (uint256 i = 0; i < protocols.length; i++) {
            _addProtocol(logicStorage, protocols[i], protocolType);
        }
    }

    function _addProtocol(AssetManagerStorage storage logicStorage, address protocol, ProtocolType protocolType)
        private
    {
        if (!_isProtocolRegistered(logicStorage.guard, protocol, protocolType)) {
            revert NotRegistered();
        }
        _protocolSet(logicStorage, protocolType).add(protocol);
        // Intent protocols validate gasless off-chain orders through their per-vault clone
        // (owner == this vault) whenever CoW calls isValidSignature. With no on-chain trade
        // call left to lazily clone them, they must be cloned at registration or the clone
        // stays address(0) and every order fails as InvalidEip1271Signature.
        if (protocolType == ProtocolType.Intent) {
            _cloneProtocol(logicStorage, protocol);
        }
    }

    function _removeProtocols(
        AssetManagerStorage storage logicStorage,
        address[] memory protocols,
        ProtocolType protocolType
    ) private {
        EnumerableSet.AddressSet storage set = _protocolSet(logicStorage, protocolType);
        for (uint256 i = 0; i < protocols.length; i++) {
            set.remove(protocols[i]);
        }
    }

    function addLendingProtocols(AssetManagerStorage storage logicStorage, address[] memory lendingProtocolAddresses)
        external
        onlyAddingProtocolsEnabled(logicStorage)
        onlyInitialized(logicStorage)
    {
        _addProtocols(logicStorage, lendingProtocolAddresses, ProtocolType.Lending);
    }

    function addStakingProtocols(AssetManagerStorage storage logicStorage, address[] memory stakingProtocolAddresses)
        external
        onlyAddingProtocolsEnabled(logicStorage)
        onlyInitialized(logicStorage)
    {
        _addProtocols(logicStorage, stakingProtocolAddresses, ProtocolType.Staking);
    }

    function removeLendingProtocols(AssetManagerStorage storage logicStorage, address[] memory lendingProtocolAddresses)
        external
        onlyInitialized(logicStorage)
    {
        _removeProtocols(logicStorage, lendingProtocolAddresses, ProtocolType.Lending);
    }

    function removeStakingProtocols(AssetManagerStorage storage logicStorage, address[] memory stakingProtocolAddresses)
        external
        onlyInitialized(logicStorage)
    {
        _removeProtocols(logicStorage, stakingProtocolAddresses, ProtocolType.Staking);
    }

    function addAMMProtocols(AssetManagerStorage storage logicStorage, address[] memory ammProtocolAddresses)
        external
        onlyAddingProtocolsEnabled(logicStorage)
        onlyInitialized(logicStorage)
    {
        _addProtocols(logicStorage, ammProtocolAddresses, ProtocolType.AMM);
    }

    function removeAMMProtocols(AssetManagerStorage storage logicStorage, address[] memory ammProtocolAddresses)
        external
        onlyInitialized(logicStorage)
    {
        _removeProtocols(logicStorage, ammProtocolAddresses, ProtocolType.AMM);
    }

    function addIntentProtocols(AssetManagerStorage storage logicStorage, address[] memory intentProtocolAddresses)
        external
        onlyAddingProtocolsEnabled(logicStorage)
        onlyInitialized(logicStorage)
    {
        _addProtocols(logicStorage, intentProtocolAddresses, ProtocolType.Intent);
    }

    function removeIntentProtocols(AssetManagerStorage storage logicStorage, address[] memory intentProtocolAddresses)
        external
        onlyInitialized(logicStorage)
    {
        _removeProtocols(logicStorage, intentProtocolAddresses, ProtocolType.Intent);
    }

    function getLendingProtocols(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.lendingProtocols.values();
    }

    function getStakingProtocols(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.stakingProtocols.values();
    }

    function getAMMProtocols(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.ammProtocols.values();
    }

    function getIntentProtocols(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.intentProtocols.values();
    }

    // ============ Internal helpers ============

    /**
     * @dev Deploy (once) and cache the vault's per-protocol EIP-1167 clone. Every caller is already
     *      behind an `onlyInitialized` external, so there is no init check here.
     */
    function _cloneProtocol(AssetManagerStorage storage logicStorage, address protocol)
        private
        returns (address clonedProtocol)
    {
        clonedProtocol = logicStorage.clonedProtocols[protocol];
        if (clonedProtocol != address(0)) {
            return clonedProtocol;
        }
        clonedProtocol = protocol.clone();
        IBittyV1Protocol(clonedProtocol).initialize(address(this));
        logicStorage.clonedProtocols[protocol] = clonedProtocol;
        return clonedProtocol;
    }

    function _addressBalance(address assetAddress) private view returns (uint256) {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        return IERC20(assetAddress).balanceOf(address(this));
    }

    function _getReceiptToken(address protocol, address asset) private view returns (address) {
        (bool success, bytes memory data) =
            protocol.staticcall(abi.encodeWithSignature("receiptTokenOf(address)", asset));
        if (success && data.length >= 32) {
            return abi.decode(data, (address));
        }
        return address(0);
    }

    function _approveReceiptToken(address protocol, address asset) private {
        address receiptToken = _getReceiptToken(protocol, asset);
        if (receiptToken != address(0)) {
            uint256 balance = IERC20(receiptToken).balanceOf(address(this));
            if (balance > 0 && IERC20(receiptToken).allowance(address(this), protocol) < balance) {
                IERC20(receiptToken).forceApprove(protocol, type(uint256).max);
            }
        }
    }

    function _checkAMMProtocol(AssetManagerStorage storage logicStorage, address ammProtocol) private view {
        if (!logicStorage.ammProtocols.contains(ammProtocol)) {
            revert InvalidAMMProtocol();
        }
        if (
            !logicStorage.guard.isAMMProtocolRegistered(ammProtocol)
                && !logicStorage.guard.isAMMProtocolDeprecated(ammProtocol)
        ) {
            revert NotRegistered();
        }
    }

    function _checkIntentProtocol(AssetManagerStorage storage logicStorage, address intentProtocol) private view {
        if (!logicStorage.intentProtocols.contains(intentProtocol)) revert InvalidIntentProtocol();
        if (logicStorage.guard.isIntentProtocolDeprecated(intentProtocol)) revert Deprecated();
        if (!logicStorage.guard.isIntentProtocolRegistered(intentProtocol)) revert NotRegistered();
    }

    function _approveNFTIfNeeded(address protocol) private {
        (bool success, bytes memory data) = protocol.staticcall(abi.encodeWithSignature("positionAssetManager()"));
        if (!success || data.length < 32) return;
        address nft = abi.decode(data, (address));
        (bool success2, bytes memory result) =
            nft.staticcall(abi.encodeWithSignature("isApprovedForAll(address,address)", address(this), protocol));
        if (!success2 || result.length < 32) return;
        bool approved = abi.decode(result, (bool));
        if (!approved) {
            nft.functionCall(abi.encodeWithSignature("setApprovalForAll(address,bool)", protocol, true));
        }
    }
}
