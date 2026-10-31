// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1AccountBase} from "./BittyV1AccountBase.sol";
import {DeFiLogic} from "./logic/DeFiLogic.sol";
import {MarketTradeLogic} from "./logic/MarketTradeLogic.sol";
import {LockLib} from "./logic/LockLib.sol";
import {PaymentCore} from "./logic/PaymentCore.sol";
import {BittyStorage} from "./logic/BittyStorage.sol";
import {IBittyV1Guard, PROTOCOL_INTENT} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AutoYield} from "./interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, PERM_YIELD, PERM_SUPPLY, PERM_MARKET_TRADE, PERM_INTENT} from "./logic/Constants.sol";
import {IBittyV1Guard as IGuard, PROTOCOL_STAKING} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1DeFi, InvalidWithdrawableProtocol} from "./interfaces/IBittyV1DeFi.sol";

/**
 * @title BittyV1VaultDeFiFacet
 * @notice The DeFi surface, delegatecalled by the vault. Authorisation is the vault's owner — `owner()`
 *         lives at a fixed ERC-7201 slot, so `_msgSender() == owner()` reads the vault's own owner — and,
 *         for what its permissions name, the vault's asset manager.
 * @dev Reached through the vault's fallback, so it never holds its own state; every function operates on
 *      the vault's co-located {DeFiStorage}.
 */
contract BittyV1VaultDeFiFacet is BittyV1AccountBase {
    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;

    error NotAutoYieldTrigger();

    /**
     * The owner is asked first. Most calls are the owner's, and the owner check is a slot the lock
     * check reads anyway, where asking the asset-manager grant first costs an extra library call and a
     * cold read on every one of them.
     */
    modifier onlyManagerWith(uint32 permission) {
        _onlyOwnerOrManagerWith(permission);
        _;
    }

    modifier notLocked() {
        LockLib.requireNotLocked();
        _;
    }

    /**
     * Refused while a market trade runs; see {MarketTradeLogic-requireNotTrading}.
     */
    modifier notTrading() {
        MarketTradeLogic.requireNotTrading();
        _;
    }

    function _onlyOwnerOrManagerWith(uint32 permission) private view {
        address sender = _msgSender();
        if (sender != owner() && !DeFiLogic.assetManagerCan(sender, permission)) {
            revert OwnableUnauthorizedAccount(sender);
        }
    }

    /**
     * A position, in or out: the owner, or the manager holding the permission for that protocol's kind —
     * staking needs {PERM_YIELD}, lending {PERM_SUPPLY}. Taking value out takes the same grant as putting
     * it in, so a grant to trade at market alone reaches no position.
     */
    function _onlyOwnerOrManagerFor(address protocol) private view {
        address sender = _msgSender();
        if (sender == owner()) return;
        if (!DeFiLogic.assetManagerCan(sender, _positionPermission(protocol))) {
            revert OwnableUnauthorizedAccount(sender);
        }
    }

    /**
     * The kind is the guard's category of the address named, so a manager must name one the guard knows.
     * The position is found by lineage, and anything reporting a lineage the guard has no category for —
     * the vault's own clone, for one — would otherwise read as lending and open a staking position to a
     * supply-only grant. The guard keeps a deprecated adapter's category, so exits through it still pass.
     */
    function _positionPermission(address protocol) private view returns (uint32) {
        uint8 category = IGuard(BITTY_GUARD).protocolCategory(protocol);
        if (category == 0) revert InvalidWithdrawableProtocol();
        return category == PROTOCOL_STAKING ? PERM_YIELD : PERM_SUPPLY;
    }

    function deposit(address protocol, address asset, uint256 amount) external notLocked notTrading {
        _onlyOwnerOrManagerFor(protocol);
        DeFiLogic.deposit(protocol, asset, amount);
    }

    function withdraw(address protocol, address asset, uint256 amount) external notTrading {
        _onlyOwnerOrManagerFor(protocol);
        DeFiLogic.withdraw(protocol, asset, amount, address(this));
    }

    function withdraws(address[] calldata protocols, address[] calldata assets, uint256[] calldata amounts)
        external
        notTrading
    {
        if (_msgSender() != owner()) {
            for (uint256 i; i < protocols.length; ++i) {
                _onlyOwnerOrManagerFor(protocols[i]);
            }
        }
        DeFiLogic.withdraws(protocols, assets, amounts, address(this));
    }

    function claimWithdrawals(address protocol, uint256[] memory ids) external notTrading {
        _onlyOwnerOrManagerFor(protocol);
        DeFiLogic.claimWithdrawals(protocol, ids);
    }

    function claimWithdrawal(address protocol, uint256 id) external notTrading {
        _onlyOwnerOrManagerFor(protocol);
        DeFiLogic.claimWithdrawalOne(protocol, id);
    }

    function getBalances(address[] calldata protocols, address[] calldata assets)
        external
        view
        returns (uint256[] memory)
    {
        return DeFiLogic.getBalances(protocols, assets);
    }

    function getPendingWithdrawalIds(address protocol) external view returns (uint256[] memory) {
        return DeFiLogic.getPendingWithdrawalIds(protocol);
    }

    function getClone(address protocol) external view returns (address) {
        return DeFiLogic.getClone(protocol);
    }

    function _onlyAutoYieldTrigger() private view {
        if (msg.sender == address(this)) return;
        address s = _msgSender();
        if (s == owner()) return;
        address trigger = DeFiLogic.autoYieldTrigger();
        if (trigger != address(0) && s == trigger) return;
        revert NotAutoYieldTrigger();
    }

    function setAssetManager(address assetManager_, uint64 expiresAt, uint32 permissions)
        external
        onlyOwner
        notLocked
        notTrading
    {
        DeFiLogic.setAssetManager(assetManager_, expiresAt, permissions);
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
        return DeFiLogic.getAssetManagerSettings();
    }

    function setAutoYieldTrigger(address trigger) external onlyOwner notLocked notTrading {
        DeFiLogic.setAutoYieldTrigger(trigger);
    }

    function autoYieldTrigger() external view returns (address) {
        return DeFiLogic.autoYieldTrigger();
    }

    function autoYield(address asset, uint256 amount) external notLocked notTrading {
        _onlyAutoYieldTrigger();
        DeFiLogic.autoYieldOne(asset, amount);
    }

    function autoYields(address[] calldata assets, uint256[] calldata amounts) external notLocked notTrading {
        _onlyAutoYieldTrigger();
        DeFiLogic.autoYield(assets, amounts);
    }

    function setAutoYielding(AutoYield calldata route) external onlyOwner notLocked notTrading {
        DeFiLogic.setAutoYieldingOne(route);
    }

    function setAutoYieldings(AutoYield[] calldata routes) external onlyOwner notLocked notTrading {
        DeFiLogic.setAutoYieldings(routes);
    }

    function getAutoYieldings(address[] calldata assets) external view returns (address[] memory) {
        return DeFiLogic.getAutoYieldings(assets);
    }

    /**
     * Under either lock the owner may still sell into a stablecoin, so an asset the escape recipient
     * cannot take — a tokenised stock, with an exchange as the whitelisted destination — is not
     * stranded. Only the owner, as a lock leaves the manager's grant dormant. The legs are checked in
     * {MarketTradeLogic-marketSell}.
     */
    function marketSell(
        address marketTrade,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmountMin,
        bytes memory path
    ) external onlyManagerWith(PERM_MARKET_TRADE) {
        MarketTradeLogic.marketSell(marketTrade, sellToken, sellAmount, buyToken, buyAmountMin, path);
    }

    function marketBuy(
        address marketTrade,
        address sellToken,
        uint256 sellAmountMax,
        address buyToken,
        uint256 buyAmount,
        bytes memory reversedPath
    ) external onlyManagerWith(PERM_MARKET_TRADE) notLocked {
        MarketTradeLogic.marketBuy(marketTrade, sellToken, sellAmountMax, buyToken, buyAmount, reversedPath);
    }

    function approveIntentSpender(address intent, address token) external onlyManagerWith(PERM_INTENT) notTrading {
        DeFiLogic.approveIntentSpender(intent, token);
    }

    function cancelIntentOrders(address intent, bytes[] calldata uids)
        external
        onlyManagerWith(PERM_INTENT)
        notLocked
        notTrading
    {
        DeFiLogic.cancelIntentOrders(intent, uids);
    }

    function cancelIntentOrder(address intent, bytes calldata uid)
        external
        onlyManagerWith(PERM_INTENT)
        notLocked
        notTrading
    {
        bytes[] memory uids = new bytes[](1);
        uids[0] = uid;
        DeFiLogic.cancelIntentOrders(intent, uids);
    }

    function updateProtocols(address[] calldata add, address[] calldata remove)
        external
        onlyOwner
        notLocked
        notTrading
    {
        DeFiLogic.updateProtocols(add, remove);
    }

    function upgradeProtocol(address protocol, address newImplementation) external onlyOwner notLocked notTrading {
        DeFiLogic.upgradeProtocol(protocol, newImplementation);
    }

    function updateAssets(address[] calldata add, address[] calldata remove) external onlyOwner notLocked notTrading {
        DeFiLogic.updateAssets(add, remove);
    }

    function isProtocolAllowed(address protocol) external view returns (bool) {
        return DeFiLogic.isProtocolAllowed(protocol);
    }

    function isAssetAllowed(address asset) external view returns (bool) {
        return DeFiLogic.assetAllowed(asset);
    }

    function usingBittyAllowList() external view returns (bool) {
        return !DeFiLogic.ownAllowListActive();
    }

    /**
     * Refused under a lock in both directions: widening to Bitty's catalogue would let a stolen key
     * reach venues the owner had shut out, and the lock freezes the vault's configuration as it stands.
     */
    function useBittyAllowList(bool use) external onlyOwner notLocked notTrading {
        if (use) {
            DeFiLogic.deactivateOwnAllowList();
        } else {
            DeFiLogic.activateOwnAllowList();
        }
    }

    function guard() external pure returns (IBittyV1Guard) {
        return IBittyV1Guard(BITTY_GUARD);
    }

    /**
     * No intent order fills while a market trade runs: its settlement would move the balances the
     * trade is judged by.
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (MarketTradeLogic.isTrading()) return 0xffffffff;
        bytes4 result = _validateThrough(IBittyV1Guard(BITTY_GUARD).getProtocols(), hash, signature);
        if (result == ERC1271_MAGIC_VALUE) return result;
        return _validateThrough(IBittyV1Guard(BITTY_GUARD).getDeprecatedProtocols(), hash, signature);
    }

    function _validateThrough(address[] memory protocols, bytes32 hash, bytes memory signature)
        private
        view
        returns (bytes4)
    {
        for (uint256 i; i < protocols.length; i++) {
            if (IBittyV1Guard(BITTY_GUARD).protocolCategory(protocols[i]) != PROTOCOL_INTENT) continue;
            address clone = DeFiLogic.getClone(protocols[i]);
            if (clone == address(0)) continue;
            try IBittyV1IntentProtocol(clone).isValidSignature(hash, signature) returns (bytes4 result) {
                if (result == ERC1271_MAGIC_VALUE) return result;
            } catch {}
        }
        return 0xffffffff;
    }

    function isOffchainOrderAuthorized(address signer, address sellToken, address buyToken, uint256 sellAmount)
        external
        view
        returns (bool)
    {
        if (MarketTradeLogic.isTrading()) return false;
        if (signer != owner() && !DeFiLogic.assetManagerCan(signer, PERM_INTENT)) {
            return false;
        }
        if (!DeFiLogic.assetAllowed(buyToken)) return false;
        if (LockLib.level() != 0 && !PaymentCore.stableCoinAllowed(buyToken)) return false;
        return IERC20(sellToken).balanceOf(address(this)) >= sellAmount;
    }

    function isOffchainCancellationAuthorized(address signer) external view returns (bool) {
        if (LockLib.level() != 0) return false;
        return signer == owner() || DeFiLogic.assetManagerCan(signer, PERM_INTENT);
    }
}
