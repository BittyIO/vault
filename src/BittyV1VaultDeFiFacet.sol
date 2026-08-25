// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1VaultBase} from "./BittyV1VaultBase.sol";
import {IBittyV1AssetManager, NotAssetManager, AssetManagerExpired} from "./interfaces/IBittyV1AssetManager.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerStorage, VaultStorage} from "./logic/Storages.sol";
import {BITTY_GUARD, INTENT_INTERFACE_ID} from "./logic/Constants.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title BittyV1VaultDeFiFacet
 * @notice The asset-management (DeFi) half of the vault: trading, yield, protocol management and
 *         trade guardrails. Deployed once as a singleton and reached by delegatecall from
 *         {BittyV1Vault}'s fallback, so it runs in the vault's storage/role context.
 * @dev Shares {BittyV1VaultBase} with the core vault so the storage layout is identical. Declares no
 *      storage of its own. Direct calls to this contract (not via a vault) run against its own empty
 *      storage and simply revert on the role/initialization checks — harmless.
 */
contract BittyV1VaultDeFiFacet is BittyV1VaultBase, IBittyV1AssetManager {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @dev Passes only for the vault's single asset manager. The owner has no implicit trading access —
     *      to trade, the owner must set itself (or an AI key) as the asset manager via {setAssetManager}.
     */
    modifier onlyAssetManager() {
        _checkAssetManager();
        _;
    }

    function _checkAssetManager() internal view {
        address sender = _msgSender();
        if (_assetManager.isActiveAssetManager(sender)) return;
        if (sender == _assetManager.assetManager) revert AssetManagerExpired();
        revert NotAssetManager();
    }

    function addLiquidity(
        address ammProtocol,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external override onlyAssetManager {
        _assetManager.addLiquidity(_vault, ammProtocol, token0, amount0, token1, amount1, data);
    }

    function removeLiquidity(address ammProtocol, bytes memory data) external override onlyAssetManager {
        _assetManager.removeLiquidity(ammProtocol, data);
    }

    function decreaseLiquidity(address ammProtocol, bytes memory data) external override onlyAssetManager {
        _assetManager.decreaseLiquidity(ammProtocol, data);
    }

    function claimAMMFees(address ammProtocol, bytes memory data) external override onlyAssetManager {
        _assetManager.claimAMMFees(ammProtocol, data);
    }

    function getLiquidities(address[] calldata ammProtocols, bytes[] calldata data)
        external
        view
        returns (uint256[] memory liquidities)
    {
        return _assetManager.getLiquidities(ammProtocols, data);
    }

    /**
     * @notice Pre-approve the intent protocol's settlement relayer for `token` (max), so gasless
     *         off-chain-signed orders can be pulled at settlement. One amortized approval per sell token.
     *         Placement is entirely off-chain (sign + post to the orderbook); the vault only custodies
     *         tokens, validates via {isValidSignature}, and grants this allowance.
     */
    function approveIntentRelayer(address intentProtocol, address token) external override onlyAssetManager {
        _assetManager.approveIntentRelayer(intentProtocol, token);
    }

    /**
     * @notice Cancel one or more gasless off-chain orders on-chain by invalidating them on the intent
     *         protocol's settlement contract. CoW's API can't soft-cancel a vault (eip1271) order, so
     *         cancellation is this owner-only on-chain invalidation; afterwards no solver can settle them.
     *         Batched so a TWAP's open parts are cancelled in one tx.
     */
    function cancelIntentOrders(address intentProtocol, bytes[] calldata orderUids) external override onlyAssetManager {
        _assetManager.cancelIntentOrders(intentProtocol, orderUids);
    }

    function cancelIntentOrder(address intentProtocol, bytes calldata orderUid) external onlyAssetManager {
        _assetManager.cancelIntentOrderOne(intentProtocol, orderUid);
    }

    function getClone(address intentProtocol) external view returns (address) {
        return _assetManager.getClone(intentProtocol);
    }

    function supply(address lendingProtocol, address assetAddress, uint256 amount) external override onlyAssetManager {
        _assetManager.supply(lendingProtocol, assetAddress, amount);
    }

    function withdraw(address lendingProtocol, address assetAddress, uint256 amount)
        external
        override
        onlyAssetManager
    {
        _assetManager.withdraw(lendingProtocol, assetAddress, amount, address(this));
    }

    function getSuppliedBalances(address[] calldata lendingProtocols, address[] calldata assetAddresses)
        external
        view
        returns (uint256[] memory balances)
    {
        return _assetManager.getSuppliedBalances(lendingProtocols, assetAddresses);
    }

    function stake(address stakingProtocol, address asset, uint256 amount) external override onlyAssetManager {
        _assetManager.stake(stakingProtocol, asset, amount);
    }

    function unstake(address stakingProtocol, address asset, uint256 amount) external override onlyAssetManager {
        _assetManager.unstake(stakingProtocol, asset, amount, address(this));
    }

    function getStakedBalances(address[] calldata stakingProtocols, address[] calldata assets)
        external
        view
        returns (uint256[] memory balances)
    {
        return _assetManager.getStakedBalances(stakingProtocols, assets);
    }

    function getUnstakeRequestIds(address stakingProtocol) external view returns (uint256[] memory) {
        return _assetManager.getUnstakeRequestIds(stakingProtocol);
    }

    function claimUnstaked(address stakingProtocol, uint256 requestId) external onlyAssetManager {
        _assetManager.claimUnstakedOne(stakingProtocol, requestId);
    }

    function claimUnstakeds(address stakingProtocol, uint256[] memory requestIds) external override onlyAssetManager {
        _assetManager.claimUnstaked(stakingProtocol, requestIds);
    }

    function disableRebalanceUntilTimestamp(uint256 timestamp) external override onlyAssetManager {
        _assetManager.disableRebalanceUntilTimestamp(timestamp);
        emit RebalanceDisabledUntil(timestamp);
    }

    /**
     * @dev Empty means NO protocol is usable by this vault — the list is the permission, and nothing
     *      is seeded here at activation. Read each entry's kind from the guard's `protocolCategory`.
     */
    function getProtocols() external view returns (address[] memory) {
        return _assetManager.getProtocols();
    }

    function guard() external pure returns (IBittyV1Guard) {
        return IBittyV1Guard(BITTY_GUARD);
    }

    /**
     * @notice Validates intent order signatures on behalf of the vault.
     *         Iterates all registered intent protocol clones and delegates to each one's
     *         isValidSignature() until a match is found. Works for any protocol
     *         (CoW Swap, UniswapX, etc.) without protocol-specific vault logic.
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        address[] memory protocols = _assetManager.getProtocols();
        for (uint256 i = 0; i < protocols.length; i++) {
            if (IBittyV1Guard(BITTY_GUARD).protocolCategory(protocols[i]) != INTENT_INTERFACE_ID) continue;
            address clone = _assetManager.clonedProtocols[protocols[i]];
            if (clone == address(0)) continue;
            try IBittyV1IntentProtocol(clone).isValidSignature(hash, signature) returns (bytes4 result) {
                if (result == 0x1626ba7e) return result;
            } catch {}
        }
        return 0xffffffff;
    }

    /**
     * @notice Authorize a gasless, off-chain-signed intent order against live vault state. Called
     *         (view/staticcall) by an intent protocol clone from its isValidSignature after it has
     *         verified the order's shape and recovered `signer`. Implements the callback declared by
     *         protocol-contracts' IBittyVaultOffchainAuth.
     * @dev The asset manager has full trading access, so authorization is just: the recovered signer is
     *      the manager, the buy leg is allow-listed, and the sell leg is backed by real balance staying
     *      at/above its minimal-balance floor. Because this is a pure view there is no reservation — an
     *      over-signed order simply fails the balance check here once its backing is gone, so nothing
     *      leaks and nothing needs cleanup.
     */
    function isOffchainOrderAuthorized(address signer, address sellToken, address buyToken, uint256 sellAmount)
        external
        view
        returns (bool)
    {
        if (!_assetManager.isActiveAssetManager(signer)) return false;
        uint256 disabledUntil = _assetManager.rebalanceDisabledUntilTimestamp;
        if (disabledUntil > 0 && block.timestamp < disabledUntil) return false;
        if (!_vault.assetAllowed(buyToken)) return false;
        uint256 bal = IERC20(sellToken).balanceOf(address(this));
        if (bal < sellAmount) return false;
        return true;
    }

    /**
     * @notice Authorize an off-chain order CANCELLATION: just that `signer` is the asset manager.
     *         Cancelling moves no funds and is allowed even while trading is paused. Implements
     *         protocol-contracts' IBittyVaultOffchainAuth.isOffchainManager.
     */
    function isOffchainManager(address signer) external view returns (bool) {
        return _assetManager.isActiveAssetManager(signer);
    }
}
