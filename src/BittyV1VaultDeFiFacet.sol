// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1AccountBase} from "./BittyV1AccountBase.sol";
import {DeFiLogic} from "./logic/DeFiLogic.sol";
import {BittyStorage, DeFiStorage} from "./logic/BittyStorage.sol";
import {IBittyV1Guard, PROTOCOL_INTENT} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AutoYield} from "./interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "./logic/Constants.sol";
import {SubOwnerExpired} from "./interfaces/IBittyV1SubVault.sol";
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

    modifier onlyAssetManager() {
        if (!DeFiLogic.isActiveAssetManager(_msgSender())) _checkOwner();
        _;
    }

    modifier onlyUnwind() {
        if (!DeFiLogic.subOwnerLapsed() && !DeFiLogic.isActiveAssetManager(_msgSender())) _checkOwner();
        _;
    }

    function _checkOwner() internal view override {
        super._checkOwner();
        uint64 expiresAt = BittyStorage.subVault().subOwnerExpiresAt;
        if (expiresAt != 0 && block.timestamp >= expiresAt) revert SubOwnerExpired();
    }

    function deposit(address protocol, address asset, uint256 amount) external onlyAssetManager {
        DeFiLogic.deposit(protocol, asset, amount);
    }

    function withdraw(address protocol, address asset, uint256 amount) external onlyUnwind {
        DeFiLogic.withdraw(protocol, asset, amount, address(this));
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

    function setAssetManager(address assetManager_, uint64 expiresAt) external onlyOwner {
        DeFiLogic.setAssetManager(assetManager_, expiresAt);
    }

    function getAssetManagerSettings()
        external
        view
        returns (address manager, uint64 expiresAt, address pendingManager, uint64 pendingAt)
    {
        return DeFiLogic.getAssetManagerSettings();
    }

    function setAutoYieldTrigger(address trigger) external onlyOwner {
        DeFiLogic.setAutoYieldTrigger(trigger);
    }

    function autoYieldTrigger() external view returns (address) {
        return DeFiLogic.autoYieldTrigger();
    }

    function autoYield(address asset) external {
        _onlyAutoYieldTrigger();
        DeFiLogic.autoYieldOne(asset);
    }

    function autoYields(address[] calldata assets) external {
        _onlyAutoYieldTrigger();
        DeFiLogic.autoYield(assets);
    }

    function setAutoYielding(AutoYield calldata route) external onlyOwner {
        DeFiLogic.setAutoYieldingOne(route);
    }

    function setAutoYieldings(AutoYield[] calldata routes) external onlyOwner {
        DeFiLogic.setAutoYieldings(routes);
    }

    function getAutoYieldings(address[] calldata assets) external view returns (address[] memory) {
        return DeFiLogic.getAutoYieldings(assets);
    }

    function addLiquidity(
        address amm,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external onlyAssetManager {
        DeFiLogic.addLiquidity(amm, token0, amount0, token1, amount1, data);
    }

    function removeLiquidity(address amm, bytes memory data) external onlyUnwind {
        DeFiLogic.removeLiquidity(amm, data);
    }

    function decreaseLiquidity(address amm, bytes memory data) external onlyUnwind {
        DeFiLogic.decreaseLiquidity(amm, data);
    }

    function claimAMMFees(address amm, bytes memory data) external onlyUnwind {
        DeFiLogic.claimAMMFees(amm, data);
    }

    function getLiquidities(address[] calldata amms, bytes[] calldata data) external view returns (uint256[] memory) {
        return DeFiLogic.getLiquidities(amms, data);
    }

    function approveIntentRelayer(address intent, address token) external onlyAssetManager {
        DeFiLogic.approveIntentRelayer(intent, token);
    }

    function cancelIntentOrders(address intent, bytes[] calldata uids) external onlyUnwind {
        DeFiLogic.cancelIntentOrders(intent, uids);
    }

    function cancelIntentOrder(address intent, bytes calldata uid) external onlyUnwind {
        DeFiLogic.cancelIntentOrderOne(intent, uid);
    }

    function disableTradeUntilTimestamp(uint256 ts) external onlyOwner {
        DeFiLogic.disableTradeUntilTimestamp(ts);
        emit IBittyV1DeFi.TradingDisabledUntil(ts);
    }

    function updateProtocols(address[] calldata add, address[] calldata remove) external onlyOwner {
        DeFiLogic.updateProtocols(add, remove);
    }

    function upgradeProtocol(address protocol, address newImplementation) external onlyOwner {
        DeFiLogic.upgradeProtocol(protocol, newImplementation);
    }

    function updateAssets(address[] calldata add, address[] calldata remove) external onlyOwner {
        DeFiLogic.updateAssets(add, remove);
    }

    function isProtocolAllowed(address protocol) external view returns (bool) {
        return DeFiLogic.isProtocolAllowed(protocol);
    }

    function isAssetAllowed(address asset) external view returns (bool) {
        return DeFiLogic.assetAllowed(asset);
    }

    function allowlistEnabled() external view returns (bool) {
        return DeFiLogic.allowlistEnabled();
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
        DeFiStorage storage $ = BittyStorage.defi();
        for (uint256 i; i < protocols.length; i++) {
            if (IBittyV1Guard(BITTY_GUARD).protocolCategory(protocols[i]) != PROTOCOL_INTENT) continue;
            address clone = $.clonedProtocols[protocols[i]];
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
        if (signer != owner() && !DeFiLogic.isActiveAssetManager(signer)) return false;
        uint256 disabledUntil = DeFiLogic.tradeDisabledUntil();
        if (disabledUntil > 0 && block.timestamp < disabledUntil) return false;
        if (!DeFiLogic.assetAllowed(buyToken)) return false;
        return IERC20(sellToken).balanceOf(address(this)) >= sellAmount;
    }

    function isOffchainCancellationAuthorized(address signer) external view returns (bool) {
        return signer == owner() || DeFiLogic.isActiveAssetManager(signer);
    }
}
