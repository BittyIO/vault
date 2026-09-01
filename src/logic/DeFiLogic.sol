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
    AssetManagerExpiryInPast,
    AssetManagerNotForSubVault,
    GrantTooLong
} from "../interfaces/IBittyV1DeFi.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {
    AddressZero,
    AmountIsZero,
    InsufficientBalance,
    NotInitialized,
    AlreadyInitialized,
    ArrayLengthMismatch,
    AutoYield,
    NotRegistered,
    Deprecated
} from "../interfaces/IBittyV1Vault.sol";
import {BittyStorage, DeFiStorage} from "./BittyStorage.sol";
import {TimelockLib} from "./TimelockLib.sol";
import {
    BITTY_GUARD,
    AMM_CATEGORY,
    INTENT_CATEGORY,
    STABLE_COIN_CATEGORY,
    MAX_DURATION,
    TRADE_DISABLE_MAX_DURATION
} from "./Constants.sol";

/**
 * @dev Minimal view into an intent protocol's settlement addresses (CoW-style): the relayer a gasless
 *      sell token is approved to, and the settlement contract an order is invalidated on to cancel it.
 */
interface IIntentRelayerSource {
    function vaultRelayer() external view returns (address);
    function settlement() external view returns (address);
}

interface IIntentSettlement {
    function invalidateOrder(bytes calldata orderUid) external;
}

/**
 * @title DeFiLogic
 * @notice The full DeFi surface — yield (deposit/withdraw/auto-yield), AMM liquidity, and intent orders
 *         — shared by the main vault (owner-operated) and every sub vault (sub-owner-operated). Operates
 *         on the co-located {DeFiStorage} at the ERC-7201 DEFI_SLOT, so the same code serves whichever
 *         host delegatecalls it.
 *
 * @dev Guard-driven. The local allowlist is consulted only while it is active (the owner's trust
 *      switch, with its OFF transition delayed): an asset/protocol must then be both guard-registered
 *      and locally allowed. There is no asset-manager grant here — authorisation (owner vs sub owner) is
 *      the host facet's job; this library only moves assets.
 */
library DeFiLogic {
    event AutoYieldTriggerSet(address indexed trigger);
    event AssetManagerSet(address indexed assetManager, uint64 expiresAt);
    event AssetManagerPending(address indexed assetManager, uint64 expiresAt, uint64 effectiveAt);

    using SafeERC20 for IERC20;
    using Clones for address;
    using Address for address;

    function initialize(bool allowlistEnabled) external {
        DeFiStorage storage $ = BittyStorage.defi();
        if ($.isInitialized) revert AlreadyInitialized();
        $.isInitialized = true;
        $.allowlistEnabled = allowlistEnabled;
    }

    function _onlyInitialized(DeFiStorage storage $) private view {
        if (!$.isInitialized) revert NotInitialized();
    }

    function _allowlistActive(DeFiStorage storage $) private returns (bool) {
        if (!$.allowlistEnabled) return false;
        if ($.allowlistDisableAt != 0 && block.timestamp >= $.allowlistDisableAt) {
            $.allowlistEnabled = false;
            $.allowlistDisableAt = 0;
            return false;
        }
        return true;
    }

    function _allowlistActiveView(DeFiStorage storage $) private view returns (bool) {
        if (!$.allowlistEnabled) return false;
        return !($.allowlistDisableAt != 0 && block.timestamp >= $.allowlistDisableAt);
    }

    function enableAllowlist() external {
        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized($);
        $.allowlistEnabled = true;
        $.allowlistDisableAt = 0;
    }

    function disableAllowlist(uint64 timelock) external {
        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized($);
        if (!$.allowlistEnabled) return;
        if (timelock == 0) {
            $.allowlistEnabled = false;
            $.allowlistDisableAt = 0;
        } else {
            $.allowlistDisableAt = uint64(block.timestamp) + timelock;
        }
    }

    function allowlistEnabled() external view returns (bool) {
        return _allowlistActiveView(BittyStorage.defi());
    }

    function setAutoYieldTrigger(address trigger) external {
        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized($);
        $.autoYieldTrigger = trigger;
        emit AutoYieldTriggerSet(trigger);
    }

    function autoYieldTrigger() external view returns (address) {
        return BittyStorage.defi().autoYieldTrigger;
    }

    function setAssetManager(address assetManager, uint64 expiresAt) external {
        if (BittyStorage.subVault().vault != address(0)) revert AssetManagerNotForSubVault();
        if (expiresAt != 0) {
            if (expiresAt <= block.timestamp) revert AssetManagerExpiryInPast();
            if (expiresAt > block.timestamp + MAX_DURATION) revert GrantTooLong();
        }

        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized($);
        _settleAssetManager($);

        if (assetManager == address(0)) {
            delete $.assetManager;
            delete $.assetManagerExpiresAt;
            _clearPendingAssetManager($);
            emit AssetManagerSet(address(0), 0);
            return;
        }

        uint64 current = $.assetManagerExpiresAt;
        bool shortening = assetManager == $.assetManager && expiresAt != 0 && (current == 0 || expiresAt < current);
        uint64 timelock = TimelockLib.effective(BittyStorage.vault().riskConfig.changeTimelock);

        if (shortening || timelock == 0) {
            $.assetManager = assetManager;
            $.assetManagerExpiresAt = expiresAt;
            _clearPendingAssetManager($);
            emit AssetManagerSet(assetManager, expiresAt);
            return;
        }

        $.pendingAssetManager = assetManager;
        $.pendingAssetManagerExpiresAt = expiresAt;
        $.pendingAssetManagerAt = uint64(block.timestamp) + timelock;
        emit AssetManagerPending(assetManager, expiresAt, $.pendingAssetManagerAt);
    }

    function _settleAssetManager(DeFiStorage storage $) private {
        uint64 at = $.pendingAssetManagerAt;
        if (at != 0 && block.timestamp >= at) {
            $.assetManager = $.pendingAssetManager;
            $.assetManagerExpiresAt = $.pendingAssetManagerExpiresAt;
            _clearPendingAssetManager($);
        }
    }

    function _clearPendingAssetManager(DeFiStorage storage $) private {
        delete $.pendingAssetManager;
        delete $.pendingAssetManagerExpiresAt;
        delete $.pendingAssetManagerAt;
    }

    function _liveGrant(DeFiStorage storage $) private view returns (address manager, uint64 expiresAt) {
        uint64 at = $.pendingAssetManagerAt;
        if (at != 0 && block.timestamp >= at) {
            return ($.pendingAssetManager, $.pendingAssetManagerExpiresAt);
        }
        return ($.assetManager, $.assetManagerExpiresAt);
    }

    function getAssetManagerSettings()
        external
        view
        returns (address manager, uint64 expiresAt, address pendingManager, uint64 pendingAt)
    {
        DeFiStorage storage $ = BittyStorage.defi();
        (manager, expiresAt) = _liveGrant($);
        return (manager, expiresAt, $.pendingAssetManager, $.pendingAssetManagerAt);
    }

    function clearDelegates() external {
        DeFiStorage storage $ = BittyStorage.defi();
        delete $.assetManager;
        delete $.assetManagerExpiresAt;
        delete $.pendingAssetManager;
        delete $.pendingAssetManagerExpiresAt;
        delete $.pendingAssetManagerAt;
        delete $.autoYieldTrigger;
        emit AssetManagerSet(address(0), 0);
        emit AutoYieldTriggerSet(address(0));
    }

    function subOwnerLapsed() external view returns (bool) {
        uint64 expiresAt = BittyStorage.subVault().subOwnerExpiresAt;
        return expiresAt != 0 && block.timestamp >= expiresAt;
    }

    function isActiveAssetManager(address account) external view returns (bool) {
        if (account == address(0)) return false;
        (address manager, uint64 expiresAt) = _liveGrant(BittyStorage.defi());
        if (account != manager) return false;
        return expiresAt == 0 || block.timestamp < expiresAt;
    }

    function updateAssets(address[] calldata addAssets, address[] calldata removeAssets) external {
        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized($);
        IBittyV1Guard guard = IBittyV1Guard(BITTY_GUARD);
        for (uint256 i; i < addAssets.length; ++i) {
            if (!guard.isAssetRegistered(addAssets[i])) revert NotRegistered();
            $.assets[addAssets[i]] = true;
        }
        for (uint256 i; i < removeAssets.length; ++i) {
            $.assets[removeAssets[i]] = false;
        }
    }

    function updateProtocols(address[] calldata addProtocols, address[] calldata removeProtocols) external {
        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized($);
        IBittyV1Guard guard = IBittyV1Guard(BITTY_GUARD);
        for (uint256 i; i < removeProtocols.length; ++i) {
            $.protocols[removeProtocols[i]] = false;
        }
        for (uint256 i; i < addProtocols.length; ++i) {
            if (!guard.isProtocolRegistered(addProtocols[i])) revert NotRegistered();
            $.protocols[addProtocols[i]] = true;
            // Intent protocols must be cloned eagerly so off-chain isValidSignature has a signer.
            if (guard.protocolCategory(addProtocols[i]) == INTENT_CATEGORY) {
                _cloneProtocol($, addProtocols[i]);
            }
        }
    }

    function _assetOK(DeFiStorage storage $, address asset) private returns (bool) {
        if (!IBittyV1Guard(BITTY_GUARD).isAssetRegistered(asset)) return false;
        return !_allowlistActive($) || $.assets[asset];
    }

    function _requireAsset(DeFiStorage storage $, address asset) private {
        if (!_assetOK($, asset)) revert NotRegistered();
    }

    function assetAllowed(address asset) external view returns (bool) {
        DeFiStorage storage $ = BittyStorage.defi();
        if (!IBittyV1Guard(BITTY_GUARD).isAssetRegistered(asset)) return false;
        return !_allowlistActiveView($) || $.assets[asset];
    }

    function stableCoinAllowed(address asset) external view returns (bool) {
        DeFiStorage storage $ = BittyStorage.defi();
        if (IBittyV1Guard(BITTY_GUARD).assetCategory(asset) != STABLE_COIN_CATEGORY) return false;
        if (!IBittyV1Guard(BITTY_GUARD).isAssetRegistered(asset)) return false;
        return !_allowlistActiveView($) || $.assets[asset];
    }

    function _depositProtocolOK(DeFiStorage storage $, address protocol) private returns (bool) {
        IBittyV1Guard guard = IBittyV1Guard(BITTY_GUARD);
        if (!guard.isProtocolRegistered(protocol)) return false;
        if (guard.isProtocolDeprecated(protocol)) return false;
        return !_allowlistActive($) || $.protocols[protocol];
    }

    function _categoryProtocolOK(DeFiStorage storage $, uint8 category, address protocol) private returns (bool) {
        if (IBittyV1Guard(BITTY_GUARD).protocolCategory(protocol) != category) return false;
        return !_allowlistActive($) || $.protocols[protocol];
    }

    function isProtocolAllowed(address protocol) external view returns (bool) {
        DeFiStorage storage $ = BittyStorage.defi();
        if (!IBittyV1Guard(BITTY_GUARD).isProtocolRegistered(protocol)) return false;
        return !_allowlistActiveView($) || $.protocols[protocol];
    }

    function deposit(address depositProtocol, address assetAddress, uint256 amount) external {
        _deposit(BittyStorage.defi(), depositProtocol, assetAddress, amount);
    }

    function _deposit(DeFiStorage storage $, address depositProtocol, address assetAddress, uint256 amount) private {
        _onlyInitialized($);
        if (!_depositProtocolOK($, depositProtocol)) revert InvalidDepositableProtocol();
        if (assetAddress == address(0)) revert AddressZero();
        if (amount == 0) revert AmountIsZero();

        address clone = _cloneProtocol($, depositProtocol);
        if (IERC20(assetAddress).allowance(address(this), clone) < amount) {
            IERC20(assetAddress).forceApprove(clone, type(uint256).max);
        }
        IBittyV1Depositable(clone).deposit(assetAddress, amount);
    }

    function withdraw(address withdrawProtocol, address assetAddress, uint256 amount, address recipient)
        external
        returns (uint256 delivered)
    {
        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized($);
        if (assetAddress == address(0)) revert AddressZero();
        if (amount == 0) revert AmountIsZero();

        address clone = $.clonedProtocols[withdrawProtocol];
        if (clone == address(0)) revert InvalidWithdrawableProtocol();
        if (amount != type(uint256).max) {
            if (IBittyV1Withdrawable(clone).getBalance(assetAddress) < amount) revert InsufficientBalance();
        }
        _approveReceiptToken(clone, assetAddress);
        return IBittyV1Withdrawable(clone).withdraw(assetAddress, amount, recipient);
    }

    function protocolBalance(address withdrawProtocol, address assetAddress) external view returns (uint256) {
        return _getBalance(BittyStorage.defi(), withdrawProtocol, assetAddress);
    }

    function getBalances(address[] calldata withdrawProtocols, address[] calldata assetAddresses)
        external
        view
        returns (uint256[] memory balances)
    {
        if (withdrawProtocols.length != assetAddresses.length) revert ArrayLengthMismatch();
        DeFiStorage storage $ = BittyStorage.defi();
        balances = new uint256[](withdrawProtocols.length);
        for (uint256 i; i < withdrawProtocols.length; ++i) {
            balances[i] = _getBalance($, withdrawProtocols[i], assetAddresses[i]);
        }
    }

    function _getBalance(DeFiStorage storage $, address withdrawProtocol, address assetAddress)
        private
        view
        returns (uint256)
    {
        if (assetAddress == address(0)) revert AddressZero();
        address clone = $.clonedProtocols[withdrawProtocol];
        if (clone == address(0)) return 0;
        return IBittyV1Withdrawable(clone).getBalance(assetAddress);
    }

    function getPendingWithdrawalIds(address withdrawProtocol) external view returns (uint256[] memory) {
        address clone = BittyStorage.defi().clonedProtocols[withdrawProtocol];
        if (clone == address(0)) return new uint256[](0);
        return IBittyV1Withdrawable(clone).getPendingWithdrawalIds();
    }

    function claimWithdrawals(address withdrawProtocol, uint256[] memory ids) external {
        if (ids.length == 0) return;
        address clone = BittyStorage.defi().clonedProtocols[withdrawProtocol];
        if (clone == address(0)) revert InvalidWithdrawableProtocol();
        IBittyV1Withdrawable(clone).claimWithdrawals(ids);
    }

    function claimWithdrawalOne(address withdrawProtocol, uint256 id) external {
        address clone = BittyStorage.defi().clonedProtocols[withdrawProtocol];
        if (clone == address(0)) revert InvalidWithdrawableProtocol();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        IBittyV1Withdrawable(clone).claimWithdrawals(ids);
    }

    function setAutoYieldingOne(AutoYield calldata route) external {
        _setAutoYielding(BittyStorage.defi(), route.asset, route.protocol);
    }

    function setAutoYieldings(AutoYield[] calldata routes) external {
        DeFiStorage storage $ = BittyStorage.defi();
        for (uint256 i; i < routes.length; ++i) {
            _setAutoYielding($, routes[i].asset, routes[i].protocol);
        }
    }

    function _setAutoYielding(DeFiStorage storage $, address assetAddress, address protocol) private {
        _onlyInitialized($);
        if (assetAddress == address(0)) revert AddressZero();
        if (protocol == address(0)) {
            delete $.autoYieldProtocols[assetAddress];
            return;
        }
        if (!_depositProtocolOK($, protocol)) revert InvalidDepositableProtocol();
        $.autoYieldProtocols[assetAddress] = protocol;
    }

    function getAutoYieldings(address[] calldata assetAddresses) external view returns (address[] memory protocols) {
        DeFiStorage storage $ = BittyStorage.defi();
        protocols = new address[](assetAddresses.length);
        for (uint256 i; i < assetAddresses.length; ++i) {
            protocols[i] = $.autoYieldProtocols[assetAddresses[i]];
        }
    }

    function autoYieldOne(address assetAddress) external {
        _autoYield(BittyStorage.defi(), assetAddress);
    }

    function autoYield(address[] calldata assetAddresses) external {
        DeFiStorage storage $ = BittyStorage.defi();
        for (uint256 i; i < assetAddresses.length; ++i) {
            _autoYield($, assetAddresses[i]);
        }
    }

    function _autoYield(DeFiStorage storage $, address assetAddress) private {
        _onlyInitialized($);
        address protocol = $.autoYieldProtocols[assetAddress];
        if (protocol == address(0)) return;
        if (assetAddress == address(0)) revert AddressZero();
        uint256 amount = IERC20(assetAddress).balanceOf(address(this));
        if (amount == 0) return;
        _deposit($, protocol, assetAddress, amount);
    }

    function addLiquidity(
        address ammProtocol,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external {
        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized($);
        if (!_categoryProtocolOK($, AMM_CATEGORY, ammProtocol)) revert InvalidAMMProtocol();
        if (IBittyV1Guard(BITTY_GUARD).isProtocolDeprecated(ammProtocol)) revert Deprecated();
        _requireAsset($, token0);
        _requireAsset($, token1);

        address clone = _cloneProtocol($, ammProtocol);
        if (token0 != address(0) && amount0 > 0 && IERC20(token0).allowance(address(this), clone) < amount0) {
            IERC20(token0).forceApprove(clone, type(uint256).max);
        }
        if (token1 != address(0) && amount1 > 0 && IERC20(token1).allowance(address(this), clone) < amount1) {
            IERC20(token1).forceApprove(clone, type(uint256).max);
        }
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).addLiquidity(data);
    }

    function removeLiquidity(address ammProtocol, bytes memory data) external {
        address clone = _ammClone(ammProtocol);
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).removeLiquidity(data);
    }

    function decreaseLiquidity(address ammProtocol, bytes memory data) external {
        address clone = _ammClone(ammProtocol);
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).decreaseLiquidity(data);
    }

    function claimAMMFees(address ammProtocol, bytes memory data) external {
        address clone = _ammClone(ammProtocol);
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).claimAMMFees(data);
    }

    function _ammClone(address ammProtocol) private view returns (address clone) {
        clone = BittyStorage.defi().clonedProtocols[ammProtocol];
        if (clone == address(0)) revert InvalidAMMProtocol();
    }

    function getLiquidities(address[] calldata ammProtocols, bytes[] calldata data)
        external
        view
        returns (uint256[] memory liquidities)
    {
        if (ammProtocols.length != data.length) revert ArrayLengthMismatch();
        DeFiStorage storage $ = BittyStorage.defi();
        liquidities = new uint256[](ammProtocols.length);
        for (uint256 i; i < ammProtocols.length; ++i) {
            address clone = $.clonedProtocols[ammProtocols[i]];
            liquidities[i] = clone == address(0) ? 0 : IBittyV1AMMProtocol(clone).getLiquidity(data[i]);
        }
    }

    function approveIntentRelayer(address intentProtocol, address token) external {
        _checkIntentProtocol(BittyStorage.defi(), intentProtocol);
        address relayer = IIntentRelayerSource(intentProtocol).vaultRelayer();
        IERC20(token).forceApprove(relayer, type(uint256).max);
    }

    function cancelIntentOrders(address intentProtocol, bytes[] calldata orderUids) external {
        _checkIntentProtocol(BittyStorage.defi(), intentProtocol);
        IIntentSettlement settlement = IIntentSettlement(IIntentRelayerSource(intentProtocol).settlement());
        for (uint256 i; i < orderUids.length; ++i) {
            settlement.invalidateOrder(orderUids[i]);
        }
    }

    function cancelIntentOrderOne(address intentProtocol, bytes calldata orderUid) external {
        _checkIntentProtocol(BittyStorage.defi(), intentProtocol);
        IIntentSettlement(IIntentRelayerSource(intentProtocol).settlement()).invalidateOrder(orderUid);
    }

    function _checkIntentProtocol(DeFiStorage storage $, address intentProtocol) private {
        if (!_categoryProtocolOK($, INTENT_CATEGORY, intentProtocol)) revert InvalidIntentProtocol();
        if (IBittyV1Guard(BITTY_GUARD).isProtocolDeprecated(intentProtocol)) revert Deprecated();
    }

    function disableTradeUntilTimestamp(uint256 timestamp) external {
        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized($);
        if (timestamp == 0) return;
        if (timestamp < $.tradeDisabledUntilTimestamp) revert disableTradeUntilTimestampTooEarly();
        if (timestamp > block.timestamp + TRADE_DISABLE_MAX_DURATION) revert disableTradeUntilTimestampTooLong();
        $.tradeDisabledUntilTimestamp = uint64(timestamp);
    }

    function tradeDisabledUntil() external view returns (uint256) {
        return BittyStorage.defi().tradeDisabledUntilTimestamp;
    }

    function getClone(address protocol) external view returns (address) {
        return BittyStorage.defi().clonedProtocols[protocol];
    }

    function _cloneProtocol(DeFiStorage storage $, address protocol) private returns (address clone) {
        clone = $.clonedProtocols[protocol];
        if (clone != address(0)) return clone;
        clone = protocol.clone();
        IBittyV1Protocol(clone).initialize(address(this));
        $.clonedProtocols[protocol] = clone;
    }

    function _getReceiptToken(address protocol, address asset) private view returns (address) {
        (bool ok, bytes memory data) = protocol.staticcall(abi.encodeWithSignature("receiptTokenOf(address)", asset));
        if (ok && data.length >= 32) return abi.decode(data, (address));
        return address(0);
    }

    function _approveReceiptToken(address protocol, address asset) private {
        address receiptToken = _getReceiptToken(protocol, asset);
        if (receiptToken == address(0)) return;
        uint256 balance = IERC20(receiptToken).balanceOf(address(this));
        if (balance > 0 && IERC20(receiptToken).allowance(address(this), protocol) < balance) {
            IERC20(receiptToken).forceApprove(protocol, type(uint256).max);
        }
    }

    function _approveNFTIfNeeded(address protocol) private {
        address nft = _positionNFT(protocol);
        if (nft == address(0)) return;
        (bool ok, bytes memory result) =
            nft.staticcall(abi.encodeWithSignature("isApprovedForAll(address,address)", address(this), protocol));
        if (!ok || result.length < 32) return;
        if (!abi.decode(result, (bool))) {
            nft.functionCall(abi.encodeWithSignature("setApprovalForAll(address,bool)", protocol, true));
        }
    }

    function checkNotProtocolNFT(address nftContract) external view {
        _revertIfPositionNFT(IBittyV1Guard(BITTY_GUARD).getProtocols(), nftContract);
        _revertIfPositionNFT(IBittyV1Guard(BITTY_GUARD).getDeprecatedProtocols(), nftContract);
    }

    function _revertIfPositionNFT(address[] memory protocols, address nftContract) private view {
        DeFiStorage storage $ = BittyStorage.defi();
        for (uint256 i; i < protocols.length; ++i) {
            if (_positionNFT(protocols[i]) == nftContract) revert ProtocolNFT();
            address clone = $.clonedProtocols[protocols[i]];
            if (clone != address(0) && _positionNFT(clone) == nftContract) revert ProtocolNFT();
        }
    }

    function _positionNFT(address protocol) private view returns (address) {
        (bool ok, bytes memory data) = protocol.staticcall(abi.encodeWithSignature("positionAssetManager()"));
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }
}
