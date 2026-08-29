// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1Depositable} from "protocol-contracts/src/interfaces/IBittyV1Depositable.sol";
import {IBittyV1Withdrawable} from "protocol-contracts/src/interfaces/IBittyV1Withdrawable.sol";
import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {IBittyV1AMMProtocol} from "protocol-contracts/src/interfaces/IBittyV1AMMProtocol.sol";
import {
    InvalidDepositableProtocol,
    InvalidWithdrawableProtocol,
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
    AutoYield,
    NotRegistered,
    Deprecated
} from "../interfaces/IBittyV1Vault.sol";
import {AssetManagerStorage, AutoYieldConfig, VaultStorage} from "./Storages.sol";
import {BITTY_GUARD, AMM_CATEGORY, INTENT_CATEGORY} from "./Constants.sol";
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
 * @notice The asset manager's full surface: yield (deposit / withdraw / auto-yield), trading (AMM
 *         liquidity and intent limit/TWAP orders), config, and protocol registration. Operates on
 *         {AssetManagerStorage}.
 */
library AssetManagerLogic {
    using SafeERC20 for IERC20;
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
        _settleAssetManager(logicStorage);

        if (assetManager == address(0)) {
            _clearAssetManager(logicStorage);
            return;
        }

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

    function assetManagerExpired(AssetManagerStorage storage logicStorage) internal view returns (bool) {
        (, uint64 expiresAt) = liveGrant(logicStorage);
        return expiresAt != 0 && expiresAt < block.timestamp;
    }

    function effectiveAssetManager(AssetManagerStorage storage logicStorage) internal view returns (address) {
        (address manager, uint64 expiresAt) = liveGrant(logicStorage);
        if (expiresAt != 0 && expiresAt < block.timestamp) return address(0);
        return manager;
    }

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

    function claimWithdrawalOne(AssetManagerStorage storage logicStorage, address withdrawProtocol, uint256 id)
        external
        onlyInitialized(logicStorage)
    {
        address clone = logicStorage.clonedProtocols[withdrawProtocol];
        if (clone == address(0)) revert InvalidWithdrawableProtocol();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        IBittyV1Withdrawable(clone).claimWithdrawals(ids);
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
        _setAutoYielding(logicStorage, route.asset, route.protocol);
    }

    function deposit(
        AssetManagerStorage storage logicStorage,
        address depositProtocol,
        address assetAddress,
        uint256 amount
    ) external onlyInitialized(logicStorage) {
        _deposit(logicStorage, depositProtocol, assetAddress, amount);
    }

    function _deposit(
        AssetManagerStorage storage logicStorage,
        address depositProtocol,
        address assetAddress,
        uint256 amount
    ) private {
        if (!logicStorage.protocols[depositProtocol]) revert InvalidDepositableProtocol();
        if (IBittyV1Guard(BITTY_GUARD).isProtocolDeprecated(depositProtocol)) {
            revert Deprecated();
        }
        if (assetAddress == address(0)) revert AddressZero();
        if (amount == 0) revert AmountIsZero();

        address clone = _cloneProtocol(logicStorage, depositProtocol);
        if (IERC20(assetAddress).allowance(address(this), clone) < amount) {
            IERC20(assetAddress).forceApprove(clone, type(uint256).max);
        }
        IBittyV1Depositable(clone).deposit(assetAddress, amount);
    }

    function withdraw(
        AssetManagerStorage storage logicStorage,
        address withdrawProtocol,
        address assetAddress,
        uint256 amount,
        address recipient
    ) external onlyInitialized(logicStorage) returns (uint256 delivered) {
        if (assetAddress == address(0)) revert AddressZero();
        if (amount == 0) revert AmountIsZero();

        address clone = logicStorage.clonedProtocols[withdrawProtocol];
        if (clone == address(0)) revert InvalidWithdrawableProtocol();
        if (amount != type(uint256).max) {
            if (IBittyV1Withdrawable(clone).getBalance(assetAddress) < amount) revert InsufficientBalance();
        }
        _approveReceiptToken(clone, assetAddress);
        return IBittyV1Withdrawable(clone).withdraw(assetAddress, amount, recipient);
    }

    function getBalances(
        AssetManagerStorage storage logicStorage,
        address[] calldata withdrawProtocols,
        address[] calldata assetAddresses
    ) external view onlyInitialized(logicStorage) returns (uint256[] memory balances) {
        if (withdrawProtocols.length != assetAddresses.length) revert ArrayLengthMismatch();
        balances = new uint256[](withdrawProtocols.length);
        for (uint256 i; i < withdrawProtocols.length; ++i) {
            balances[i] = _getBalance(logicStorage, withdrawProtocols[i], assetAddresses[i]);
        }
    }

    function protocolBalance(AssetManagerStorage storage logicStorage, address withdrawProtocol, address assetAddress)
        external
        view
        returns (uint256)
    {
        return _getBalance(logicStorage, withdrawProtocol, assetAddress);
    }

    function _getBalance(AssetManagerStorage storage logicStorage, address withdrawProtocol, address assetAddress)
        private
        view
        returns (uint256)
    {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        address _clonedProtocol = logicStorage.clonedProtocols[withdrawProtocol];
        if (_clonedProtocol == address(0)) {
            return 0;
        }
        return IBittyV1Withdrawable(_clonedProtocol).getBalance(assetAddress);
    }

    function getPendingWithdrawalIds(AssetManagerStorage storage logicStorage, address withdrawProtocol)
        external
        view
        onlyInitialized(logicStorage)
        returns (uint256[] memory)
    {
        address _clonedProtocol = logicStorage.clonedProtocols[withdrawProtocol];
        if (_clonedProtocol == address(0)) {
            return new uint256[](0);
        }
        return IBittyV1Withdrawable(_clonedProtocol).getPendingWithdrawalIds();
    }

    function claimWithdrawals(AssetManagerStorage storage logicStorage, address withdrawProtocol, uint256[] memory ids)
        external
        onlyInitialized(logicStorage)
    {
        if (ids.length == 0) {
            return;
        }
        withdrawProtocol = logicStorage.clonedProtocols[withdrawProtocol];
        if (withdrawProtocol == address(0)) {
            revert InvalidWithdrawableProtocol();
        }
        IBittyV1Withdrawable(withdrawProtocol).claimWithdrawals(ids);
    }

    function setAutoYieldings(AssetManagerStorage storage logicStorage, AutoYield[] calldata routes)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i; i < routes.length; ++i) {
            _setAutoYielding(logicStorage, routes[i].asset, routes[i].protocol);
        }
    }

    function registerAutoYield(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        AutoYield memory route
    ) external onlyInitialized(logicStorage) {
        if (route.protocol == address(0)) revert AddressZero();
        VaultLogic.addAsset(vaultStorage, route.asset);
        _setAutoYielding(logicStorage, route.asset, route.protocol);
    }

    function _setAutoYielding(AssetManagerStorage storage logicStorage, address assetAddress, address protocol)
        private
    {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (protocol == address(0)) {
            delete logicStorage.autoYieldConfigs[assetAddress];
            return;
        }

        if (!logicStorage.protocols[protocol]) {
            if (logicStorage.addingProtocolsDisabled) {
                revert AddingProtocolsDisabled();
            }
            _addProtocol(logicStorage, protocol);
        }
        logicStorage.autoYieldConfigs[assetAddress] = AutoYieldConfig({protocol: protocol});
    }

    function getAutoYieldings(AssetManagerStorage storage logicStorage, address[] calldata assetAddresses)
        external
        view
        returns (address[] memory protocols)
    {
        protocols = new address[](assetAddresses.length);
        for (uint256 i; i < assetAddresses.length; ++i) {
            AutoYieldConfig storage cfg = logicStorage.autoYieldConfigs[assetAddresses[i]];
            protocols[i] = cfg.protocol;
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
        _deposit(logicStorage, cfg.protocol, assetAddress, amount);
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

    function _guardAllows(address protocol, uint8 category) private view returns (bool) {
        return IBittyV1Guard(BITTY_GUARD).protocolCategory(protocol) == category;
    }

    /**
     * @dev Only AMM and intent reach here. Those two are routed by what they are - an AMM takes
     *      liquidity, an intent relayer signs orders - so the vault has to match the guard's category
     *      exactly. Depositing and withdrawing ask no such question: they go by capability, and any
     *      category that speaks those interfaces works without being named here.
     */
    function protocolAllowed(AssetManagerStorage storage logicStorage, uint8 category, address protocol)
        internal
        view
        returns (bool)
    {
        return logicStorage.protocols[protocol] && _guardAllows(protocol, category);
    }

    function _addProtocol(AssetManagerStorage storage logicStorage, address protocol) private {
        IBittyV1Guard guard = IBittyV1Guard(BITTY_GUARD);
        if (!guard.isProtocolRegistered(protocol)) {
            revert NotRegistered();
        }
        logicStorage.protocols[protocol] = true;
        uint8 category = guard.protocolCategory(protocol);
        if (category == INTENT_CATEGORY) {
            // Lazy clone not works for off-chain isValidSignature
            _cloneProtocol(logicStorage, protocol);
        }
    }

    function _removeProtocol(AssetManagerStorage storage logicStorage, address protocol) private {
        logicStorage.protocols[protocol] = false;
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
        if (!protocolAllowed(logicStorage, AMM_CATEGORY, ammProtocol)) {
            revert InvalidAMMProtocol();
        }
    }

    function _checkIntentProtocol(AssetManagerStorage storage logicStorage, address intentProtocol) private view {
        if (!protocolAllowed(logicStorage, INTENT_CATEGORY, intentProtocol)) revert InvalidIntentProtocol();
        if (IBittyV1Guard(BITTY_GUARD).isProtocolDeprecated(intentProtocol)) revert Deprecated();
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
        _revertIfPositionNFT(logicStorage, IBittyV1Guard(BITTY_GUARD).getProtocols(), nftContract);
        _revertIfPositionNFT(logicStorage, IBittyV1Guard(BITTY_GUARD).getDeprecatedProtocols(), nftContract);
    }

    function _revertIfPositionNFT(
        AssetManagerStorage storage logicStorage,
        address[] memory protocols,
        address nftContract
    ) private view {
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
