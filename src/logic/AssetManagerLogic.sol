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
    disableTradeUntilTimestampTooEarly,
    disableTradeUntilTimestampTooLong,
    InvalidAMMProtocol,
    InvalidIntentProtocol,
    ProtocolNFT,
    AssetManagerExpiryInPast
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
    ArrayLengthMismatch,
    AutoYield
} from "../interfaces/IBittyV1Vault.sol";
import {AssetManagerStorage, AutoYieldConfig, VaultStorage} from "./Storages.sol";
import {
    BITTY_GUARD,
    LENDING_INTERFACE_ID,
    STAKING_INTERFACE_ID,
    AMM_INTERFACE_ID,
    INTENT_INTERFACE_ID
} from "./Constants.sol";
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

    function initialize(AssetManagerStorage storage logicStorage) external onlyNotInitialized(logicStorage) {
        logicStorage.isInitialized = true;
    }

    function getClone(AssetManagerStorage storage logicStorage, address protocol) external view returns (address) {
        return logicStorage.clonedProtocols[protocol];
    }

    function initAssetManager(AssetManagerStorage storage logicStorage, address assetManager)
        external
        onlyInitialized(logicStorage)
    {
        logicStorage.assetManager = assetManager;
        logicStorage.assetManagerExpiresAt = 0;
    }

    function setAssetManager(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address assetManager,
        uint64 expiresAt
    ) external onlyInitialized(logicStorage) {
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert AssetManagerExpiryInPast();

        // Settle first so a matured grant becomes the CURRENT one before anything is compared
        // against it — otherwise "shortening the current manager" would be judged against the
        // manager it already replaced.
        _settleAssetManager(logicStorage);

        if (assetManager == address(0)) {
            _clearAssetManager(logicStorage);
            return;
        }

        // Shortening a live grant: same manager, and an expiry that arrives sooner than the one they
        // already have (an unset expiry never arrives, so any expiry shortens it).
        uint64 current = logicStorage.assetManagerExpiresAt;
        bool shortening =
            assetManager == logicStorage.assetManager && expiresAt != 0 && (current == 0 || expiresAt < current);
        uint64 timelock = VaultLogic.effectiveChangeTimelock(vaultStorage);
        if (shortening || timelock == 0) {
            logicStorage.assetManager = assetManager;
            logicStorage.assetManagerExpiresAt = expiresAt;
            _clearPendingAssetManager(logicStorage);
            return;
        }

        logicStorage.pendingAssetManager = assetManager;
        logicStorage.pendingAssetManagerExpiresAt = expiresAt;
        logicStorage.pendingAssetManagerAt = uint64(block.timestamp) + timelock;
    }

    /**
     * @dev Fold a matured pending grant into the live one. Read paths do not need this — they read
     *      through — but any path that WRITES the grant must settle first, or it would compare
     *      against or overwrite a manager that is no longer the effective one.
     */
    function _settleAssetManager(AssetManagerStorage storage logicStorage) private {
        uint64 at = logicStorage.pendingAssetManagerAt;
        if (at != 0 && block.timestamp >= at) {
            logicStorage.assetManager = logicStorage.pendingAssetManager;
            logicStorage.assetManagerExpiresAt = logicStorage.pendingAssetManagerExpiresAt;
            _clearPendingAssetManager(logicStorage);
        }
    }

    function _clearPendingAssetManager(AssetManagerStorage storage logicStorage) private {
        delete logicStorage.pendingAssetManager;
        delete logicStorage.pendingAssetManagerExpiresAt;
        delete logicStorage.pendingAssetManagerAt;
    }

    function _clearAssetManager(AssetManagerStorage storage logicStorage) private {
        delete logicStorage.assetManager;
        delete logicStorage.assetManagerExpiresAt;
        _clearPendingAssetManager(logicStorage);
    }

    /**
     * @dev The grant in force right now, reading THROUGH a scheduled change that has matured. Nobody
     *      has to send a transaction to finalise a timelock for it to take effect, which is the same
     *      rule {TimelockedValue} follows for the risk controls.
     */
    function liveGrant(AssetManagerStorage storage logicStorage)
        internal
        view
        returns (address manager, uint64 expiresAt)
    {
        uint64 at = logicStorage.pendingAssetManagerAt;
        if (at != 0 && block.timestamp >= at) {
            return (logicStorage.pendingAssetManager, logicStorage.pendingAssetManagerExpiresAt);
        }
        return (logicStorage.assetManager, logicStorage.assetManagerExpiresAt);
    }

    /**
     * @dev Has the grant in force lapsed? Matches the convention used for every other optional bound
     *      in the vault: 0 means unset, so an unset expiry never expires.
     */
    function assetManagerExpired(AssetManagerStorage storage logicStorage) internal view returns (bool) {
        (, uint64 expiresAt) = liveGrant(logicStorage);
        return expiresAt != 0 && expiresAt < block.timestamp;
    }

    /**
     * @notice The manager whose authority is live right now — address(0) once the grant has lapsed.
     * @dev Every authorization path reads this rather than the raw field, so an expired grant is
     *      indistinguishable from no grant at all. The raw pair is {IBittyV1Vault-getAssetManagerSettings}.
     */
    function effectiveAssetManager(AssetManagerStorage storage logicStorage) internal view returns (address) {
        (address manager, uint64 expiresAt) = liveGrant(logicStorage);
        if (expiresAt != 0 && expiresAt < block.timestamp) return address(0);
        return manager;
    }

    /**
     * @dev address(0) can never be the manager, so an unset vault does not authorize a caller that
     *      arrives with no sender — and an expired one authorizes nobody.
     */
    function isActiveAssetManager(AssetManagerStorage storage logicStorage, address account)
        internal
        view
        returns (bool)
    {
        return account != address(0) && account == effectiveAssetManager(logicStorage);
    }

    function prepareRenounceAssetManager(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address owner
    ) external onlyInitialized(logicStorage) returns (address remaining) {
        _settleAssetManager(logicStorage);
        _clearPendingAssetManager(logicStorage);

        if (logicStorage.assetManager == owner || VaultLogic.effectiveChangeTimelock(vaultStorage) == 0) {
            delete logicStorage.assetManager;
            delete logicStorage.assetManagerExpiresAt;
            return address(0);
        }
        return effectiveAssetManager(logicStorage);
    }

    function autoYieldOne(AssetManagerStorage storage logicStorage, address assetAddress)
        external
        onlyInitialized(logicStorage)
    {
        _autoYield(logicStorage, assetAddress);
    }

    function claimUnstakedOne(AssetManagerStorage storage logicStorage, address stakingProtocol, uint256 requestId)
        external
        onlyInitialized(logicStorage)
    {
        address clone = logicStorage.clonedProtocols[stakingProtocol];
        if (clone == address(0)) revert InvalidStakingProtocol();
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        IBittyV1StakingProtocol(clone).claimUnstaked(ids);
    }

    function cancelIntentOrderOne(
        AssetManagerStorage storage logicStorage,
        address intentProtocol,
        bytes calldata orderUid
    ) external {
        _checkIntentProtocol(logicStorage, intentProtocol);
        IIntentSettlement(IIntentRelayerSource(intentProtocol).settlement()).invalidateOrder(orderUid);
    }

    function setAutoYieldingOne(AssetManagerStorage storage logicStorage, AutoYield calldata route)
        external
        onlyInitialized(logicStorage)
    {
        _setAutoYielding(logicStorage, route.asset, route.protocol, route.isSupplying);
    }

    function supply(
        AssetManagerStorage storage logicStorage,
        address lendingProtocol,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        _supply(logicStorage, lendingProtocol, assetAddress, amount);
    }

    function _supply(
        AssetManagerStorage storage logicStorage,
        address lendingProtocol,
        address assetAddress,
        uint256 amount
    ) private {
        if (!protocolAllowed(logicStorage, LENDING_INTERFACE_ID, lendingProtocol)) {
            revert InvalidLendingProtocol();
        }
        if (IBittyV1Guard(BITTY_GUARD).isProtocolDeprecated(lendingProtocol)) {
            revert Deprecated();
        }
        if (assetAddress == address(0)) revert AddressZero();
        if (amount == 0) revert AmountIsZero();
        lendingProtocol = _cloneProtocol(logicStorage, lendingProtocol);
        if (IERC20(assetAddress).allowance(address(this), lendingProtocol) < amount) {
            IERC20(assetAddress).forceApprove(lendingProtocol, type(uint256).max);
        }
        IBittyV1LendingProtocol(lendingProtocol).supply(assetAddress, amount);
    }

    function withdraw(
        AssetManagerStorage storage logicStorage,
        address lendingProtocol,
        address assetAddress,
        uint256 amount,
        address recipient
    ) external onlyInitialized(logicStorage) returns (uint256 delivered) {
        if (assetAddress == address(0)) revert AddressZero();
        if (amount == 0) revert AmountIsZero();
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

    function getSuppliedBalances(
        AssetManagerStorage storage logicStorage,
        address[] calldata lendingProtocols,
        address[] calldata assetAddresses
    ) external view onlyInitialized(logicStorage) returns (uint256[] memory balances) {
        if (lendingProtocols.length != assetAddresses.length) revert ArrayLengthMismatch();
        balances = new uint256[](lendingProtocols.length);
        for (uint256 i; i < lendingProtocols.length; ++i) {
            balances[i] = _getSuppliedBalance(logicStorage, lendingProtocols[i], assetAddresses[i]);
        }
    }

    function _getSuppliedBalance(
        AssetManagerStorage storage logicStorage,
        address lendingProtocol,
        address assetAddress
    ) private view returns (uint256) {
        address _clonedProtocol = logicStorage.clonedProtocols[lendingProtocol];
        if (_clonedProtocol == address(0)) {
            return 0;
        }
        return IBittyV1LendingProtocol(_clonedProtocol).getSuppliedBalance(assetAddress);
    }

    function stake(
        AssetManagerStorage storage logicStorage,
        address stakingProtocol,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        _stake(logicStorage, stakingProtocol, assetAddress, amount);
    }

    function _stake(
        AssetManagerStorage storage logicStorage,
        address stakingProtocol,
        address assetAddress,
        uint256 amount
    ) private {
        if (!protocolAllowed(logicStorage, STAKING_INTERFACE_ID, stakingProtocol)) {
            revert InvalidStakingProtocol();
        }
        if (IBittyV1Guard(BITTY_GUARD).isProtocolDeprecated(stakingProtocol)) {
            revert Deprecated();
        }
        if (assetAddress == address(0)) revert AddressZero();
        if (amount == 0) revert AmountIsZero();
        stakingProtocol = _cloneProtocol(logicStorage, stakingProtocol);
        if (IERC20(assetAddress).allowance(address(this), stakingProtocol) < amount) {
            IERC20(assetAddress).forceApprove(stakingProtocol, type(uint256).max);
        }
        IBittyV1StakingProtocol(stakingProtocol).stake(assetAddress, amount);
    }

    function unstake(
        AssetManagerStorage storage logicStorage,
        address stakingProtocol,
        address assetAddress,
        uint256 amount,
        address recipient
    ) external onlyInitialized(logicStorage) returns (uint256 delivered) {
        if (assetAddress == address(0)) revert AddressZero();
        if (amount == 0) revert AmountIsZero();
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

    function getStakedBalances(
        AssetManagerStorage storage logicStorage,
        address[] calldata stakingProtocols,
        address[] calldata assetAddresses
    ) external view onlyInitialized(logicStorage) returns (uint256[] memory balances) {
        if (stakingProtocols.length != assetAddresses.length) revert ArrayLengthMismatch();
        balances = new uint256[](stakingProtocols.length);
        for (uint256 i; i < stakingProtocols.length; ++i) {
            balances[i] = _getStakedBalance(logicStorage, stakingProtocols[i], assetAddresses[i]);
        }
    }

    function _getStakedBalance(AssetManagerStorage storage logicStorage, address stakingProtocol, address assetAddress)
        private
        view
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

    function setAutoYieldings(AssetManagerStorage storage logicStorage, AutoYield[] calldata routes)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i; i < routes.length; ++i) {
            _setAutoYielding(logicStorage, routes[i].asset, routes[i].protocol, routes[i].isSupplying);
        }
    }

    function registerAutoYield(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        AutoYield memory route
    ) external onlyInitialized(logicStorage) {
        if (route.protocol == address(0)) revert AddressZero();
        VaultLogic.addAsset(vaultStorage, route.asset);
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

        bytes4 required = isSupplying ? LENDING_INTERFACE_ID : STAKING_INTERFACE_ID;
        if (!_guardAllows(protocol, required)) {
            if (isSupplying) revert InvalidLendingProtocol();
            revert InvalidStakingProtocol();
        }

        if (!logicStorage.protocols.contains(protocol)) {
            if (logicStorage.addingProtocolsDisabled) {
                revert AddingProtocolsDisabled();
            }
            _addProtocol(logicStorage, protocol);
        }
        logicStorage.autoYieldConfigs[assetAddress] = AutoYieldConfig({protocol: protocol, isSupplying: isSupplying});
    }

    function getAutoYieldings(AssetManagerStorage storage logicStorage, address[] calldata assetAddresses)
        external
        view
        returns (address[] memory protocols, bool[] memory isSupplyings)
    {
        protocols = new address[](assetAddresses.length);
        isSupplyings = new bool[](assetAddresses.length);
        for (uint256 i; i < assetAddresses.length; ++i) {
            AutoYieldConfig storage cfg = logicStorage.autoYieldConfigs[assetAddresses[i]];
            protocols[i] = cfg.protocol;
            isSupplyings[i] = cfg.isSupplying;
        }
    }

    function autoYield(AssetManagerStorage storage logicStorage, address[] calldata assetAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i; i < assetAddresses.length; ++i) {
            _autoYield(logicStorage, assetAddresses[i]);
        }
    }

    function _autoYield(AssetManagerStorage storage logicStorage, address assetAddress)
        private
        returns (uint256 amount)
    {
        AutoYieldConfig memory cfg = logicStorage.autoYieldConfigs[assetAddress];
        if (cfg.protocol == address(0)) {
            return 0;
        }
        amount = _addressBalance(assetAddress);
        if (amount == 0) {
            return 0;
        }
        if (cfg.isSupplying) {
            _supply(logicStorage, cfg.protocol, assetAddress, amount);
        } else {
            _stake(logicStorage, cfg.protocol, assetAddress, amount);
        }
    }

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
        if (IBittyV1Guard(BITTY_GUARD).isProtocolDeprecated(ammProtocol)) revert Deprecated();

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

    function getLiquidities(
        AssetManagerStorage storage logicStorage,
        address[] calldata ammProtocols,
        bytes[] calldata data
    ) external view returns (uint256[] memory liquidities) {
        if (ammProtocols.length != data.length) revert ArrayLengthMismatch();
        liquidities = new uint256[](ammProtocols.length);
        for (uint256 i; i < ammProtocols.length; ++i) {
            liquidities[i] = _getLiquidity(logicStorage, ammProtocols[i], data[i]);
        }
    }

    function _getLiquidity(AssetManagerStorage storage logicStorage, address ammProtocol, bytes calldata data)
        private
        view
        returns (uint256)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) return 0;
        return IBittyV1AMMProtocol(clone).getLiquidity(data);
    }

    function disableTradeUntilTimestamp(AssetManagerStorage storage logicStorage, uint256 timestamp)
        external
        onlyInitialized(logicStorage)
    {
        if (timestamp == 0) {
            return;
        }
        if (timestamp < logicStorage.tradeDisabledUntilTimestamp) {
            revert disableTradeUntilTimestampTooEarly();
        }
        if (timestamp > block.timestamp + REBALANCE_DISABLE_MAX_DURATION) {
            revert disableTradeUntilTimestampTooLong();
        }
        logicStorage.tradeDisabledUntilTimestamp = uint64(timestamp);
    }

    function approveIntentRelayer(AssetManagerStorage storage logicStorage, address intentProtocol, address token)
        external
    {
        _checkIntentProtocol(logicStorage, intentProtocol);
        address relayer = IIntentRelayerSource(intentProtocol).vaultRelayer();
        IERC20(token).forceApprove(relayer, type(uint256).max);
    }

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

    function disableAddingProtocols(AssetManagerStorage storage logicStorage) external onlyInitialized(logicStorage) {
        logicStorage.addingProtocolsDisabled = true;
    }

    function _guardAllows(address protocol, bytes4 categoryInterfaceId) private view returns (bool) {
        return IBittyV1Guard(BITTY_GUARD).protocolCategory(protocol) == categoryInterfaceId;
    }

    function protocolAllowed(AssetManagerStorage storage logicStorage, bytes4 categoryInterfaceId, address protocol)
        internal
        view
        returns (bool)
    {
        return logicStorage.protocols.contains(protocol) && _guardAllows(protocol, categoryInterfaceId);
    }

    function _addProtocol(AssetManagerStorage storage logicStorage, address protocol) private {
        IBittyV1Guard guard = IBittyV1Guard(BITTY_GUARD);
        if (!guard.isProtocolRegistered(protocol)) {
            revert NotRegistered();
        }
        logicStorage.protocols.add(protocol);
        bytes4 category = guard.protocolCategory(protocol);
        if (category == INTENT_INTERFACE_ID) {
            // Lazy clone not works for off-chain isValidSignature
            _cloneProtocol(logicStorage, protocol);
        }
    }

    function _removeProtocol(AssetManagerStorage storage logicStorage, address protocol) private {
        logicStorage.protocols.remove(protocol);
    }

    function updateProtocols(
        AssetManagerStorage storage logicStorage,
        address[] memory addProtocolAddresses,
        address[] memory removeProtocolAddresses
    ) external onlyInitialized(logicStorage) {
        for (uint256 i = 0; i < removeProtocolAddresses.length; i++) {
            _removeProtocol(logicStorage, removeProtocolAddresses[i]);
        }
        if (addProtocolAddresses.length > 0) {
            if (logicStorage.addingProtocolsDisabled) {
                revert AddingProtocolsDisabled();
            }
            for (uint256 i = 0; i < addProtocolAddresses.length; i++) {
                _addProtocol(logicStorage, addProtocolAddresses[i]);
            }
        }
    }

    function getProtocols(AssetManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.protocols.values();
    }

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
        if (!protocolAllowed(logicStorage, AMM_INTERFACE_ID, ammProtocol)) {
            revert InvalidAMMProtocol();
        }
        if (
            !_guardAllows(ammProtocol, AMM_INTERFACE_ID)
                && !IBittyV1Guard(BITTY_GUARD).isProtocolDeprecated(ammProtocol)
        ) {
            revert NotRegistered();
        }
    }

    function _checkIntentProtocol(AssetManagerStorage storage logicStorage, address intentProtocol) private view {
        if (!protocolAllowed(logicStorage, INTENT_INTERFACE_ID, intentProtocol)) revert InvalidIntentProtocol();
        if (IBittyV1Guard(BITTY_GUARD).isProtocolDeprecated(intentProtocol)) revert Deprecated();
        if (!_guardAllows(intentProtocol, INTENT_INTERFACE_ID)) revert NotRegistered();
    }

    function _approveNFTIfNeeded(address protocol) private {
        address nft = _positionNFT(protocol);
        if (nft == address(0)) return;
        (bool success2, bytes memory result) =
            nft.staticcall(abi.encodeWithSignature("isApprovedForAll(address,address)", address(this), protocol));
        if (!success2 || result.length < 32) return;
        bool approved = abi.decode(result, (bool));
        if (!approved) {
            nft.functionCall(abi.encodeWithSignature("setApprovalForAll(address,bool)", protocol, true));
        }
    }

    function checkNotProtocolNFT(AssetManagerStorage storage logicStorage, address nftContract) external view {
        address[] memory protocols = IBittyV1Guard(BITTY_GUARD).getProtocols();
        for (uint256 i = 0; i < protocols.length; i++) {
            if (_positionNFT(protocols[i]) == nftContract) revert ProtocolNFT();
            address clone = logicStorage.clonedProtocols[protocols[i]];
            if (clone != address(0) && _positionNFT(clone) == nftContract) revert ProtocolNFT();
        }
    }

    function _positionNFT(address protocol) private view returns (address) {
        (bool success, bytes memory data) = protocol.staticcall(abi.encodeWithSignature("positionAssetManager()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }
}
