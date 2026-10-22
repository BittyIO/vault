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
import {IBittyV1DeFi} from "./interfaces/IBittyV1DeFi.sol";

/**
 * @title BittyV1VaultDeFiFacet
 * @notice The DeFi surface, written once and delegatecalled by both the main vault and every sub vault.
 *         Authorisation is the inherited {onlyOwner}: since `owner()` lives at OZ's fixed ERC-7201 slot,
 *         `_msgSender() == owner()` resolves to the main owner inside the main vault and the sub owner
 *         inside a sub vault — the same code, correct authority in each host.
 * @dev Reached through each host's fallback, so it never holds its own state; every function operates on
 *      the host's co-located {DeFiStorage}. The allowlist *switch* is deliberately NOT here (that stays
 *      host-controlled — main owner / parent); only the list *content* is, since narrowing is pure
 *      self-restriction.
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

    modifier onlyUnwind() {
        address sender = _msgSender();
        if (sender != owner() && !DeFiLogic.isActiveAssetManager(sender)) revert OwnableUnauthorizedAccount(sender);
        _;
    }

    function _onlyOwnerOrManagerWith(uint32 permission) private view {
        address sender = _msgSender();
        if (sender != owner() && !DeFiLogic.assetManagerCan(sender, permission)) {
            revert OwnableUnauthorizedAccount(sender);
        }
    }

    function deposit(address protocol, address asset, uint256 amount) external notLocked {
        address sender = _msgSender();
        if (sender != owner()) {
            uint32 permission =
                IGuard(BITTY_GUARD).protocolCategory(protocol) == PROTOCOL_STAKING ? PERM_YIELD : PERM_SUPPLY;
            if (!DeFiLogic.assetManagerCan(sender, permission)) revert OwnableUnauthorizedAccount(sender);
        }
        DeFiLogic.deposit(protocol, asset, amount);
    }

    function withdraw(address protocol, address asset, uint256 amount) external onlyUnwind {
        DeFiLogic.withdraw(protocol, asset, amount, address(this));
    }

    function withdraws(address[] calldata protocols, address[] calldata assets, uint256[] calldata amounts)
        external
        onlyUnwind
    {
        DeFiLogic.withdraws(protocols, assets, amounts, address(this));
    }

    function claimWithdrawals(address protocol, uint256[] memory ids) external onlyUnwind {
        DeFiLogic.claimWithdrawals(protocol, ids);
    }

    function claimWithdrawal(address protocol, uint256 id) external onlyUnwind {
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

    function setAssetManager(address assetManager_, uint64 expiresAt, uint32 permissions) external onlyOwner notLocked {
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

    function setAutoYieldTrigger(address trigger) external onlyOwner notLocked {
        DeFiLogic.setAutoYieldTrigger(trigger);
    }

    function autoYieldTrigger() external view returns (address) {
        return DeFiLogic.autoYieldTrigger();
    }

    function autoYield(address asset, uint256 amount) external notLocked {
        _onlyAutoYieldTrigger();
        DeFiLogic.autoYieldOne(asset, amount);
    }

    function autoYields(address[] calldata assets, uint256[] calldata amounts) external notLocked {
        _onlyAutoYieldTrigger();
        DeFiLogic.autoYield(assets, amounts);
    }

    function setAutoYielding(AutoYield calldata route) external onlyOwner notLocked {
        DeFiLogic.setAutoYieldingOne(route);
    }

    function setAutoYieldings(AutoYield[] calldata routes) external onlyOwner notLocked {
        DeFiLogic.setAutoYieldings(routes);
    }

    function getAutoYieldings(address[] calldata assets) external view returns (address[] memory) {
        return DeFiLogic.getAutoYieldings(assets);
    }

    function marketSell(
        address marketTrade,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmountMin,
        bytes memory path
    ) external onlyManagerWith(PERM_MARKET_TRADE) notLocked {
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

    function approveIntentSpender(address intent, address token) external onlyManagerWith(PERM_INTENT) {
        DeFiLogic.approveIntentSpender(intent, token);
    }

    function cancelIntentOrders(address intent, bytes[] calldata uids) external onlyUnwind notLocked {
        DeFiLogic.cancelIntentOrders(intent, uids);
    }

    function cancelIntentOrder(address intent, bytes calldata uid) external onlyUnwind notLocked {
        bytes[] memory uids = new bytes[](1);
        uids[0] = uid;
        DeFiLogic.cancelIntentOrders(intent, uids);
    }

    function updateProtocols(address[] calldata add, address[] calldata remove) external onlyOwner notLocked {
        DeFiLogic.updateProtocols(add, remove);
    }

    function upgradeProtocol(address protocol, address newImplementation) external onlyOwner notLocked {
        DeFiLogic.upgradeProtocol(protocol, newImplementation);
    }

    function updateAssets(address[] calldata add, address[] calldata remove) external onlyOwner notLocked {
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

    function useBittyAllowList(bool use) external onlyOwner {
        if (use) {
            DeFiLogic.deactivateOwnAllowList();
        } else {
            LockLib.requireNotLocked();
            DeFiLogic.activateOwnAllowList();
        }
    }

    function guard() external pure returns (IBittyV1Guard) {
        return IBittyV1Guard(BITTY_GUARD);
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
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
        if (signer != owner() && !DeFiLogic.assetManagerCan(signer, PERM_INTENT)) {
            return false;
        }
        if (!DeFiLogic.assetAllowed(buyToken)) return false;
        if (LockLib.level() != 0 && !PaymentCore.stableCoinAllowed(buyToken)) return false;
        return IERC20(sellToken).balanceOf(address(this)) >= sellAmount;
    }

    function isOffchainCancellationAuthorized(address signer) external view returns (bool) {
        if (LockLib.level() != 0) return false;
        return signer == owner() || DeFiLogic.isActiveAssetManager(signer);
    }
}
