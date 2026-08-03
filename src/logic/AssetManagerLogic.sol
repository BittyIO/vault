// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IBittyV1Guard, NotRegistered, Deprecated} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {
    StableCoinInvestCapZero,
    InvalidLendingProtocol,
    InvalidStakingProtocol
} from "../interfaces/IBittyV1AssetManager.sol";
import {IBittyV1LendingProtocol} from "protocol-contracts/src/interfaces/IBittyV1LendingProtocol.sol";
import {IBittyV1StakingProtocol} from "protocol-contracts/src/interfaces/IBittyV1StakingProtocol.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    AddressZero,
    AmountIsZero,
    InsufficientBalance,
    NotInitialized,
    AlreadyInitialized,
    AddingProtocolsDisabled
} from "../interfaces/IBittyV1Vault.sol";
import {AssetManagerStorage, TradeLimit, AutoYieldConfig} from "./Storages.sol";
import {AssetManagerShared} from "./AssetManagerShared.sol";

/**
 * @title AssetManagerLogic
 * @notice The asset manager's yield (lending / staking / auto-yield) surface, plus asset-manager
 *         config and protocol registration. Trading (market swaps, AMM liquidity, intent limit/TWAP
 *         orders) lives in {AssetManagerTradeLogic}; the two share {AssetManagerShared} and operate on
 *         the same {AssetManagerStorage}. Split so each deployed library stays under the EIP-170
 *         24,576-byte limit.
 */
library AssetManagerLogic {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

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
     * @notice Set the vault's single (restricted) asset manager and its trade guardrail, replacing any
     * previous asset manager. Reverts if `stableCoinInvestCap == 0`.
     */
    function setAssetManager(
        AssetManagerStorage storage logicStorage,
        address assetManager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt,
        uint64 activationDelay
    ) external onlyInitialized(logicStorage) {
        if (assetManager == address(0)) revert AddressZero();
        if (stableCoinInvestCap == 0) revert StableCoinInvestCapZero();
        logicStorage.assetManager = assetManager;
        logicStorage.assetManagerActiveAt = uint64(block.timestamp) + activationDelay;
        TradeLimit storage limit = logicStorage.assetManagerLimit;
        limit.interval = uint64(interval);
        limit.maxStableCoinPerTrade = uint64(maxStableCoinPerTrade);
        limit.stableCoinInvestCap = uint64(stableCoinInvestCap);
        limit.expiredAt = uint96(expiredAt);
        // A restricted asset manager: reset the tracked portfolio and any prior full-access grant.
        limit.stableCoinInvested = 0;
        limit.lastTradeTimestamp = 0;
        limit.fullAccess = false;
    }

    /**
     * @notice Set the vault's single asset manager as full-access: bounded only by minimal balances,
     * skipping the per-trade cap / invest cap / throttle / stablecoin-leg checks. For keys as trusted as
     * the owner. Replaces any previous asset manager.
     */
    function setFullAssetManager(AssetManagerStorage storage logicStorage, address assetManager, uint64 activationDelay)
        external
        onlyInitialized(logicStorage)
    {
        if (assetManager == address(0)) revert AddressZero();
        logicStorage.assetManager = assetManager;
        logicStorage.assetManagerActiveAt = uint64(block.timestamp) + activationDelay;
        delete logicStorage.assetManagerLimit;
        logicStorage.assetManagerLimit.fullAccess = true;
    }

    function removeAssetManager(AssetManagerStorage storage logicStorage) external onlyInitialized(logicStorage) {
        logicStorage.assetManager = address(0);
        logicStorage.assetManagerActiveAt = 0;
        delete logicStorage.assetManagerLimit;
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
        lendingProtocol = AssetManagerShared.cloneProtocol(logicStorage, lendingProtocol);
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
        stakingProtocol = AssetManagerShared.cloneProtocol(logicStorage, stakingProtocol);
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
     * @dev The protocol must already be registered on the vault for the chosen kind — autoYield can
     * never route funds anywhere the owner hasn't enabled. Re-validated again at execution time, so a
     * later protocol removal or deprecation disables the route rather than bypassing the check.
     */
    function setAutoYielding(
        AssetManagerStorage storage logicStorage,
        address assetAddress,
        address protocol,
        bool isSupplying
    ) external onlyInitialized(logicStorage) {
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
        uint256 balance = AssetManagerShared.addressBalance(assetAddress);
        uint256 reserved = logicStorage.committedIntentSell[assetAddress] + logicStorage.minimalBalances[assetAddress];
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

    // ============ Receipt-token / staking helpers ============

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

    // ============ Protocol registration ============

    function disableAddingProtocols(AssetManagerStorage storage logicStorage) external onlyInitialized(logicStorage) {
        logicStorage.addingProtocolsDisabled = true;
    }

    // Which protocol registry an add/remove targets. Lets the four protocol kinds share one
    // add/remove implementation instead of repeating the loop + guard check four times each.
    enum ProtocolType {
        Lending,
        Staking,
        AMM,
        Intent
    }

    function _protocolSet(AssetManagerStorage storage logicStorage, ProtocolType kind)
        private
        view
        returns (EnumerableSet.AddressSet storage)
    {
        if (kind == ProtocolType.Lending) return logicStorage.lendingProtocols;
        if (kind == ProtocolType.Staking) return logicStorage.stakingProtocols;
        if (kind == ProtocolType.AMM) return logicStorage.ammProtocols;
        return logicStorage.intentProtocols;
    }

    function _isProtocolRegistered(IBittyV1Guard guard, address protocol, ProtocolType kind)
        private
        view
        returns (bool)
    {
        if (kind == ProtocolType.Lending) return guard.isLendingProtocolRegistered(protocol);
        if (kind == ProtocolType.Staking) return guard.isStakingProtocolRegistered(protocol);
        if (kind == ProtocolType.AMM) return guard.isAMMProtocolRegistered(protocol);
        return guard.isIntentProtocolRegistered(protocol);
    }

    function _addProtocols(AssetManagerStorage storage logicStorage, address[] memory protocols, ProtocolType kind)
        private
    {
        EnumerableSet.AddressSet storage set = _protocolSet(logicStorage, kind);
        for (uint256 i = 0; i < protocols.length; i++) {
            if (!_isProtocolRegistered(logicStorage.guard, protocols[i], kind)) {
                revert NotRegistered();
            }
            set.add(protocols[i]);
        }
    }

    function _removeProtocols(AssetManagerStorage storage logicStorage, address[] memory protocols, ProtocolType kind)
        private
    {
        EnumerableSet.AddressSet storage set = _protocolSet(logicStorage, kind);
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
}
