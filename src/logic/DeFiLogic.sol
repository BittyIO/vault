// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IBittyV1Guard, ASSET_STABLE_COIN, PROTOCOL_INTENT} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1Yield} from "protocol-contracts/src/interfaces/IBittyV1Yield.sol";
import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {
    InvalidDepositableProtocol,
    InvalidWithdrawableProtocol,
    InvalidIntentProtocol,
    ProtocolNotInstantiated,
    ProtocolLineageMismatch,
    ProtocolNotNewer,
    AssetManagerExpiryInPast,
    GrantTooLong
} from "../interfaces/IBittyV1DeFi.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    AddressZero,
    AmountIsZero,
    NotInitialized,
    ArrayLengthMismatch,
    AutoYield,
    NotRegistered,
    Deprecated
} from "../interfaces/IBittyV1Vault.sol";
import {BittyStorage, DeFiStorage, ProtocolInstance} from "./BittyStorage.sol";
import {RiskLogic} from "./RiskLogic.sol";
import {BITTY_GUARD, MAX_GRANT_DURATION} from "./Constants.sol";

/**
 * @title DeFiLogic
 * @notice The full DeFi surface — yield (deposit/withdraw/auto-yield), market making, market trading
 * and intent orders
 *         — run in the vault's context. Operates on the co-located {DeFiStorage} at the ERC-7201
 *         DEFI_SLOT.
 *
 * @dev Guard-driven. The local allowlist is consulted only while it is active (the owner's trust
 *      switch, with its OFF transition delayed): an asset/protocol must then be both guard-registered
 *      and locally allowed. This library stores the asset-manager grant and answers who holds it, but
 *      does not authorise calls — that is the facet's job ({BittyV1VaultDeFiFacet}).
 */
library DeFiLogic {
    event AutoYieldTriggerSet(address indexed trigger);
    event AssetManagerSet(address indexed assetManager, uint64 expiresAt);
    event AssetManagerPending(address indexed assetManager, uint64 expiresAt, uint64 effectiveAt);
    event AssetManagerPermissionsSet(address indexed assetManager, uint32 permissions);

    using SafeERC20 for IERC20;

    function listInitialAsset(address asset) external {
        DeFiStorage storage $ = BittyStorage.defi();
        if (asset == address(0) || $.assets[asset]) return;
        (bool ok, bytes memory data) = BITTY_GUARD.staticcall(abi.encodeCall(IBittyV1Guard.isAssetRegistered, (asset)));
        if (!ok || data.length < 32 || !abi.decode(data, (bool))) return;
        $.assets[asset] = true;
    }

    function _onlyInitialized() internal view {
        if (!BittyStorage.vault().isInitialized) revert NotInitialized();
    }

    function activateOwnAllowList() external {
        _onlyInitialized();
        BittyStorage.vault().ownAllowListActive = true;
    }

    function deactivateOwnAllowList() external {
        _onlyInitialized();
        BittyStorage.vault().ownAllowListActive = false;
    }

    function ownAllowListActive() external view returns (bool) {
        return BittyStorage.vault().ownAllowListActive;
    }

    function setAutoYieldTrigger(address trigger) external {
        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized();
        $.autoYieldTrigger = trigger;
        emit AutoYieldTriggerSet(trigger);
    }

    function autoYieldTrigger() external view returns (address) {
        return BittyStorage.defi().autoYieldTrigger;
    }

    /**
     * @dev Every grant expires: `expiresAt` must be in the future (0 is in the past, so it is refused
     *      as one) and within {MAX_GRANT_DURATION}. A revoke ignores it.
     */
    function setAssetManager(address assetManager, uint64 expiresAt, uint32 permissions) external {
        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized();
        _settleAssetManager($);

        if (assetManager == address(0)) {
            delete $.assetManager;
            delete $.assetManagerExpiresAt;
            delete $.assetManagerPerms;
            _clearPendingAssetManager($);
            emit AssetManagerSet(address(0), 0);
            return;
        }

        if (expiresAt <= block.timestamp) revert AssetManagerExpiryInPast();
        if (expiresAt > block.timestamp + MAX_GRANT_DURATION) revert GrantTooLong();

        bool sameManager = assetManager == $.assetManager;
        bool noLaterExpiry = expiresAt <= $.assetManagerExpiresAt;
        bool noNewPermission = permissions & ~$.assetManagerPerms == 0;
        bool tightening = sameManager && noLaterExpiry && noNewPermission;
        uint64 timelock = RiskLogic.effectiveTimelock(BittyStorage.vault().riskConfig);

        if (tightening) {
            $.assetManager = assetManager;
            $.assetManagerExpiresAt = uint48(expiresAt);
            $.assetManagerPerms = permissions;
            _clearPendingAssetManager($);
            emit AssetManagerSet(assetManager, expiresAt);
            emit AssetManagerPermissionsSet(assetManager, permissions);
            return;
        }

        $.pendingAssetManager = assetManager;
        $.pendingAssetManagerExpiresAt = uint48(expiresAt);
        $.pendingAssetManagerPerms = permissions;
        $.pendingAssetManagerAt = uint48(uint64(block.timestamp) + timelock);
        $.hasPendingAssetManager = true;
        emit AssetManagerPending(assetManager, expiresAt, $.pendingAssetManagerAt);
    }

    function _settleAssetManager(DeFiStorage storage $) private {
        if (!$.hasPendingAssetManager) return;
        if (block.timestamp >= $.pendingAssetManagerAt) {
            $.assetManager = $.pendingAssetManager;
            $.assetManagerExpiresAt = $.pendingAssetManagerExpiresAt;
            $.assetManagerPerms = $.pendingAssetManagerPerms;
            _clearPendingAssetManager($);
        }
    }

    function _clearPendingAssetManager(DeFiStorage storage $) private {
        delete $.pendingAssetManager;
        delete $.pendingAssetManagerExpiresAt;
        delete $.pendingAssetManagerPerms;
        delete $.pendingAssetManagerAt;
        delete $.hasPendingAssetManager;
    }

    function _liveGrant(DeFiStorage storage $)
        private
        view
        returns (address manager, uint64 expiresAt, uint32 permissions)
    {
        if ($.hasPendingAssetManager && block.timestamp >= $.pendingAssetManagerAt) {
            return ($.pendingAssetManager, $.pendingAssetManagerExpiresAt, $.pendingAssetManagerPerms);
        }
        return ($.assetManager, $.assetManagerExpiresAt, $.assetManagerPerms);
    }

    function getAssetManagerSettings()
        external
        view
        returns (
            address manager,
            uint64 expiresAt,
            address pendingManager,
            uint64 pendingAt,
            uint32 permissions,
            uint32 pendingPermissions
        )
    {
        DeFiStorage storage $ = BittyStorage.defi();
        (manager, expiresAt, permissions) = _liveGrant($);
        if (block.timestamp >= expiresAt) permissions = 0; // no manager reads as expiry 0
        pendingManager = $.pendingAssetManager;
        pendingAt = $.pendingAssetManagerAt;
        pendingPermissions = $.hasPendingAssetManager ? $.pendingAssetManagerPerms : 0;
    }

    function _pendingAssetManagerGrant() internal view returns (address manager, uint64 at, uint32 permissions) {
        DeFiStorage storage $ = BittyStorage.defi();
        if (!$.hasPendingAssetManager) return (address(0), 0, 0);
        return ($.pendingAssetManager, $.pendingAssetManagerAt, $.pendingAssetManagerPerms);
    }

    function assetManagerCan(address account, uint32 permissions) external view returns (bool) {
        if (account == address(0)) return false;
        (address manager, uint64 expiresAt, uint32 granted) = _liveGrant(BittyStorage.defi());
        if (account != manager) return false;
        if (block.timestamp >= expiresAt) return false;
        return granted & permissions == permissions;
    }

    function upgradeProtocol(address protocol, address newImplementation) external {
        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized();
        address instance = _instanceOf($, protocol);
        if (instance == address(0)) revert ProtocolNotInstantiated();
        if (!IBittyV1Guard(BITTY_GUARD).isProtocolRegistered(newImplementation)) revert NotRegistered();
        bytes32 lineage = IBittyV1Protocol(instance).protocolLineage();
        if (lineage == bytes32(0) || IBittyV1Protocol(newImplementation).protocolLineage() != lineage) {
            revert ProtocolLineageMismatch();
        }
        if (IBittyV1Protocol(newImplementation).protocolVersion() <= IBittyV1Protocol(instance).protocolVersion()) {
            revert ProtocolNotNewer();
        }
        UUPSUpgradeable(instance).upgradeToAndCall(newImplementation, "");
        ++$.clonedProtocols[lineage].version;
    }

    function updateAssets(address[] calldata addAssets, address[] calldata removeAssets) external {
        DeFiStorage storage $ = BittyStorage.defi();
        _onlyInitialized();
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
        _onlyInitialized();
        IBittyV1Guard guard = IBittyV1Guard(BITTY_GUARD);
        for (uint256 i; i < removeProtocols.length; ++i) {
            $.protocols[removeProtocols[i]] = false;
        }
        for (uint256 i; i < addProtocols.length; ++i) {
            if (!guard.isProtocolRegistered(addProtocols[i])) revert NotRegistered();
            $.protocols[addProtocols[i]] = true;
            // Intent protocols must be cloned eagerly so off-chain isValidSignature has a signer.
            if (guard.protocolCategory(addProtocols[i]) == PROTOCOL_INTENT) {
                _cloneProtocol($, addProtocols[i]);
            }
        }
    }

    function assetAllowed(address asset) external view returns (bool) {
        DeFiStorage storage $ = BittyStorage.defi();
        if (!IBittyV1Guard(BITTY_GUARD).isAssetRegistered(asset)) return false;
        return !BittyStorage.vault().ownAllowListActive || $.assets[asset];
    }

    function stableCoinAllowed(address asset) external view returns (bool) {
        DeFiStorage storage $ = BittyStorage.defi();
        if ((IBittyV1Guard(BITTY_GUARD).assetCategory(asset) & ASSET_STABLE_COIN) == 0) return false;
        if (!IBittyV1Guard(BITTY_GUARD).isAssetRegistered(asset)) return false;
        return !BittyStorage.vault().ownAllowListActive || $.assets[asset];
    }

    /**
     * Registered is enough: deprecating a protocol takes it out of the guard's registered set, so a
     * deprecated one already fails here and a second guard call to ask would only cost gas.
     */
    function _depositProtocolOK(DeFiStorage storage $, address protocol) private view returns (bool) {
        if (!IBittyV1Guard(BITTY_GUARD).isProtocolRegistered(protocol)) return false;
        return !BittyStorage.vault().ownAllowListActive || $.protocols[protocol];
    }

    function _categoryProtocolOK(DeFiStorage storage $, uint8 category, address protocol) private view returns (bool) {
        if (IBittyV1Guard(BITTY_GUARD).protocolCategory(protocol) != category) return false;
        return !BittyStorage.vault().ownAllowListActive || $.protocols[protocol];
    }

    function isProtocolAllowed(address protocol) external view returns (bool) {
        DeFiStorage storage $ = BittyStorage.defi();
        if (!IBittyV1Guard(BITTY_GUARD).isProtocolRegistered(protocol)) return false;
        return !BittyStorage.vault().ownAllowListActive || $.protocols[protocol];
    }

    function deposit(address depositProtocol, address assetAddress, uint256 amount) external {
        _deposit(BittyStorage.defi(), depositProtocol, assetAddress, amount);
    }

    function _deposit(DeFiStorage storage $, address depositProtocol, address assetAddress, uint256 amount) private {
        _onlyInitialized();
        if (!_depositProtocolOK($, depositProtocol)) revert InvalidDepositableProtocol();
        if (assetAddress == address(0)) revert AddressZero();
        if (amount == 0) revert AmountIsZero();

        address clone = _cloneProtocol($, depositProtocol);
        if (IERC20(assetAddress).allowance(address(this), clone) < amount) {
            IERC20(assetAddress).forceApprove(clone, type(uint256).max);
        }
        IBittyV1Yield(clone).deposit(assetAddress, amount);
    }

    function withdraw(address withdrawProtocol, address assetAddress, uint256 amount, address recipient)
        external
        returns (uint256 delivered)
    {
        return _withdraw(BittyStorage.defi(), withdrawProtocol, assetAddress, amount, recipient);
    }

    function withdraws(
        address[] calldata withdrawProtocols,
        address[] calldata assetAddresses,
        uint256[] calldata amounts,
        address recipient
    ) external {
        uint256 n = withdrawProtocols.length;
        if (assetAddresses.length != n || amounts.length != n) revert ArrayLengthMismatch();
        DeFiStorage storage $ = BittyStorage.defi();
        for (uint256 i; i < n; ++i) {
            _withdraw($, withdrawProtocols[i], assetAddresses[i], amounts[i], recipient);
        }
    }

    function _withdraw(
        DeFiStorage storage $,
        address withdrawProtocol,
        address assetAddress,
        uint256 amount,
        address recipient
    ) private returns (uint256 delivered) {
        _onlyInitialized();
        if (assetAddress == address(0)) revert AddressZero();
        if (amount == 0) revert AmountIsZero();

        ProtocolInstance memory instance = _instance($, withdrawProtocol);
        address clone = instance.clone;
        if (clone == address(0)) revert InvalidWithdrawableProtocol();
        _approveReceiptToken($, instance, assetAddress); // no balance check to save gas
        return IBittyV1Yield(clone).withdraw(assetAddress, amount, recipient);
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
        address clone = _instanceOf($, withdrawProtocol);
        if (clone == address(0)) return 0;
        return IBittyV1Yield(clone).getBalance(assetAddress);
    }

    function getPendingWithdrawalIds(address withdrawProtocol) external view returns (uint256[] memory) {
        address clone = _instanceOf(BittyStorage.defi(), withdrawProtocol);
        if (clone == address(0)) return new uint256[](0);
        return IBittyV1Yield(clone).getPendingWithdrawalIds();
    }

    function claimWithdrawals(address withdrawProtocol, uint256[] memory ids) external {
        if (ids.length == 0) return;
        address clone = _instanceOf(BittyStorage.defi(), withdrawProtocol);
        if (clone == address(0)) revert InvalidWithdrawableProtocol();
        IBittyV1Yield(clone).claimWithdrawals(ids);
    }

    function claimWithdrawalOne(address withdrawProtocol, uint256 id) external {
        address clone = _instanceOf(BittyStorage.defi(), withdrawProtocol);
        if (clone == address(0)) revert InvalidWithdrawableProtocol();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        IBittyV1Yield(clone).claimWithdrawals(ids);
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
        _onlyInitialized();
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

    function autoYieldOne(address assetAddress, uint256 amount) external {
        _autoYield(BittyStorage.defi(), assetAddress, amount);
    }

    function autoYield(address[] calldata assetAddresses, uint256[] calldata amounts) external {
        if (assetAddresses.length != amounts.length) revert ArrayLengthMismatch();
        DeFiStorage storage $ = BittyStorage.defi();
        for (uint256 i; i < assetAddresses.length; ++i) {
            _autoYield($, assetAddresses[i], amounts[i]);
        }
    }

    /**
     * @dev The caller names the amount so a fee float can stay behind; it is capped at the free
     *      balance rather than refused, because that moves between the keeper reading it and this.
     */
    function _autoYield(DeFiStorage storage $, address assetAddress, uint256 amount) private {
        _onlyInitialized();
        address protocol = $.autoYieldProtocols[assetAddress];
        if (protocol == address(0)) return;
        if (assetAddress == address(0)) revert AddressZero();
        uint256 balance = IERC20(assetAddress).balanceOf(address(this));
        if (amount > balance) amount = balance;
        if (amount == 0) return;
        _deposit($, protocol, assetAddress, amount);
    }

    /**
     * Intent protocols are driven through the clone alone, like yield: the vault approves whatever the
     * clone names as its {IBittyV1IntentProtocol-spender} and asks the clone to cancel. Nothing here
     * knows which intent protocol it is talking to.
     */
    function approveIntentSpender(address intentProtocol, address token) external {
        DeFiStorage storage $ = BittyStorage.defi();
        if (!_categoryProtocolOK($, PROTOCOL_INTENT, intentProtocol)) revert InvalidIntentProtocol();
        if (IBittyV1Guard(BITTY_GUARD).isProtocolDeprecated(intentProtocol)) revert Deprecated();
        address spender = IBittyV1IntentProtocol(_cloneProtocol($, intentProtocol)).spender();
        IERC20(token).forceApprove(spender, type(uint256).max);
    }

    /**
     * @dev Deprecation does NOT block a cancel. The vault's isValidSignature keeps validating through a
     *      deprecated protocol's clone so its in-flight orders still settle; refusing to cancel them
     *      would leave orders that can fill but cannot be withdrawn.
     */
    function cancelIntentOrders(address intentProtocol, bytes[] calldata orderIds) external {
        DeFiStorage storage $ = BittyStorage.defi();
        if (!_categoryProtocolOK($, PROTOCOL_INTENT, intentProtocol)) revert InvalidIntentProtocol();
        IBittyV1IntentProtocol(_cloneProtocol($, intentProtocol)).cancelOrders(orderIds);
    }

    function getClone(address protocol) external view returns (address) {
        return _instanceOf(BittyStorage.defi(), protocol);
    }

    function _lineageOf(address protocol) private view returns (bytes32 lineage) {
        if (protocol == address(0)) return bytes32(0);
        (bool ok, bytes memory data) =
            protocol.staticcall(abi.encodeWithSelector(IBittyV1Protocol.protocolLineage.selector));
        if (ok && data.length >= 32) lineage = abi.decode(data, (bytes32));
    }

    function _instanceOf(DeFiStorage storage $, address protocol) private view returns (address) {
        return _instance($, protocol).clone;
    }

    function _instance(DeFiStorage storage $, address protocol) private view returns (ProtocolInstance memory) {
        bytes32 lineage = _lineageOf(protocol);
        if (lineage == bytes32(0)) return ProtocolInstance({clone: address(0), version: 0});
        return $.clonedProtocols[lineage];
    }

    function _cloneProtocol(DeFiStorage storage $, address protocol) internal returns (address clone) {
        bytes32 lineage = IBittyV1Protocol(protocol).protocolLineage();
        if (lineage == bytes32(0)) revert ProtocolLineageMismatch();
        clone = $.clonedProtocols[lineage].clone;
        if (clone != address(0)) return clone;
        clone = address(new ERC1967Proxy(protocol, abi.encodeCall(IBittyV1Protocol.initialize, (address(this)))));
        $.clonedProtocols[lineage].clone = clone;
    }

    function _getReceiptToken(address protocol, address asset) private view returns (address) {
        (bool ok, bytes memory data) = protocol.staticcall(abi.encodeWithSignature("receiptTokenOf(address)", asset));
        if (ok && data.length >= 32) return abi.decode(data, (address));
        return address(0);
    }

    /**
     * Let the clone pull the receipt token it takes back on a withdrawal. Done once per clone version
     * and asset, then remembered: asking the clone for the token and the token for an allowance costs
     * three calls on every withdrawal otherwise. A clone upgrade moves the version, since a new
     * adapter may name a different receipt token.
     */
    function _approveReceiptToken(DeFiStorage storage $, ProtocolInstance memory instance, address asset) private {
        uint32 approvedAt = instance.version + 1;
        if ($.receiptTokenApproved[instance.clone][asset] == approvedAt) return;
        address receiptToken = _getReceiptToken(instance.clone, asset);
        if (receiptToken == address(0)) return;
        if (IERC20(receiptToken).allowance(address(this), instance.clone) != type(uint256).max) {
            IERC20(receiptToken).forceApprove(instance.clone, type(uint256).max);
        }
        $.receiptTokenApproved[instance.clone][asset] = approvedAt;
    }
}
