// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1VaultBase} from "./BittyV1VaultBase.sol";
import {IBittyV1Manager, NotManager} from "./interfaces/IBittyV1Manager.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {ManagerLogic} from "./logic/ManagerLogic.sol";
import {ManagerStorage} from "./logic/Storages.sol";

/**
 * @title BittyV1VaultDeFiFacet
 * @notice The asset-management (DeFi) half of the vault: trading, yield, protocol management and
 *         trade guardrails. Deployed once as a singleton and reached by delegatecall from
 *         {BittyV1Vault}'s fallback, so it runs in the vault's storage/role context.
 * @dev Shares {BittyV1VaultBase} with the core vault so the storage layout is identical. Declares no
 *      storage of its own. Direct calls to this contract (not via a vault) run against its own empty
 *      storage and simply revert on the role/initialization checks — harmless.
 */
contract BittyV1VaultDeFiFacet is BittyV1VaultBase, IBittyV1Manager {
    using ManagerLogic for ManagerStorage;

    /**
     * @dev Passes only for the vault's single manager. The owner has no implicit trading access —
     *      to trade, the owner must set itself (or an AI key) as the manager via {setManager} /
     *      {setFullManager}.
     */
    modifier onlyManager() {
        _checkManager();
        _;
    }

    function _checkManager() internal view {
        if (_msgSender() != _manager.manager) revert NotManager();
    }

    // ============ AMM ============

    function marketSell(
        address ammProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external override onlyManager {
        _manager.marketSell(_vault, ammProtocol, from, to, sellAmount, buyAmountMin, data);
    }

    function marketBuy(
        address ammProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        bytes memory data
    ) external override onlyManager {
        _manager.marketBuy(_vault, ammProtocol, from, to, buyAmount, sellAmountMax, data);
    }

    function addLiquidity(
        address ammProtocol,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external override onlyManager {
        _manager.addLiquidity(ammProtocol, token0, amount0, token1, amount1, data);
    }

    function removeLiquidity(address ammProtocol, bytes memory data) external override onlyManager {
        _manager.removeLiquidity(ammProtocol, data);
    }

    function decreaseLiquidity(address ammProtocol, bytes memory data) external override onlyManager {
        _manager.decreaseLiquidity(ammProtocol, data);
    }

    function claimAMMFees(address ammProtocol, bytes memory data) external override onlyManager {
        _manager.claimAMMFees(ammProtocol, data);
    }

    function getLiquidity(address ammProtocol, bytes memory data) external view returns (uint256) {
        return _manager.getLiquidity(ammProtocol, data);
    }

    // ============ Intent ============

    function limitSell(
        address intentProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        uint32 validTo
    ) external override onlyManager returns (bytes32 orderId) {
        return _manager.limitSell(_vault, intentProtocol, from, to, sellAmount, buyAmountMin, validTo);
    }

    function limitBuy(
        address intentProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        uint32 validTo
    ) external override onlyManager returns (bytes32 orderId) {
        return _manager.limitBuy(_vault, intentProtocol, from, to, buyAmount, sellAmountMax, validTo);
    }

    function cancelLimitOrder(address intentProtocol, bytes memory data) external override onlyManager {
        _manager.cancelLimitOrder(intentProtocol, data);
    }

    function cleanExpiredLimitOrders(address intentProtocol, bytes32[] calldata orderDigests) external {
        _manager.cleanExpiredLimitOrders(intentProtocol, orderDigests);
    }

    function twapSell(
        address intentProtocol,
        address from,
        address to,
        uint256 totalSellAmount,
        uint256 minPartLimit,
        uint256 n,
        uint256 partDuration,
        uint256 span
    ) external override onlyManager returns (bytes32 twapId) {
        return _manager.twapSell(_vault, intentProtocol, from, to, totalSellAmount, minPartLimit, n, partDuration, span);
    }

    function cancelTwapOrder(address intentProtocol, bytes32 twapId) external override onlyManager {
        _manager.cancelTwapOrder(intentProtocol, twapId);
    }

    function twapBuy(
        address intentProtocol,
        address from,
        address to,
        uint256 totalBuyAmount,
        uint256 sellAmountPerPart,
        uint256 n,
        uint256 partDuration,
        uint256 span
    ) external override onlyManager returns (bytes32 twapId) {
        return _manager.twapBuy(
            _vault, intentProtocol, from, to, totalBuyAmount, sellAmountPerPart, n, partDuration, span
        );
    }

    function getIntentProtocols() external view returns (address[] memory) {
        return _manager.getIntentProtocols();
    }

    function getClone(address intentProtocol) external view returns (address) {
        return _manager.getClone(intentProtocol);
    }

    // ============ Lending ============

    function supply(address lendingProtocol, address assetAddress, uint256 amount) external override onlyManager {
        _manager.supply(lendingProtocol, assetAddress, amount);
    }

    function withdraw(address lendingProtocol, address assetAddress, uint256 amount) external override onlyManager {
        _manager.withdraw(lendingProtocol, assetAddress, amount, address(this));
    }

    function getSuppliedBalance(address lendingProtocol, address assetAddress) external view returns (uint256) {
        return _manager.getSuppliedBalance(lendingProtocol, assetAddress);
    }

    // ============ Staking ============

    function stake(address stakingProtocol, address asset, uint256 amount) external override onlyManager {
        _manager.stake(stakingProtocol, asset, amount);
    }

    function unstake(address stakingProtocol, address asset, uint256 amount) external override onlyManager {
        _manager.unstake(stakingProtocol, asset, amount, address(this));
    }

    function getStakedBalance(address stakingProtocol, address asset) external view returns (uint256) {
        return _manager.getStakedBalance(stakingProtocol, asset);
    }

    function getUnstakeRequestIds(address stakingProtocol) external view returns (uint256[] memory) {
        return _manager.getUnstakeRequestIds(stakingProtocol);
    }

    function claimUnstaked(address stakingProtocol, uint256[] memory requestIds) external override onlyManager {
        _manager.claimUnstaked(stakingProtocol, requestIds);
    }

    // ============ Rebalance ============

    function disableRebalanceUntilTimestamp(uint256 timestamp) external override onlyManager {
        _manager.disableRebalanceUntilTimestamp(timestamp);
        emit RebalanceDisabledUntil(timestamp);
    }

    function getLendingProtocols() external view returns (address[] memory) {
        return _manager.getLendingProtocols();
    }

    function getStakingProtocols() external view returns (address[] memory) {
        return _manager.getStakingProtocols();
    }

    function getAMMProtocols() external view returns (address[] memory) {
        return _manager.getAMMProtocols();
    }

    // ============ Views ============

    function guard() external view returns (IBittyV1Guard) {
        return _manager.guard;
    }

    function minimalBalance(address assetAddress) external view returns (uint256) {
        return _manager.minimalBalances[assetAddress];
    }

    // ============ EIP-1271 (intent order signature validation) ============

    /**
     * @notice Validates intent order signatures on behalf of the vault.
     *         Iterates all registered intent protocol clones and delegates to each one's
     *         isValidSignature() until a match is found. Works for any protocol
     *         (CoW Swap, UniswapX, etc.) without protocol-specific vault logic.
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        address[] memory protocols = _manager.getIntentProtocols();
        for (uint256 i = 0; i < protocols.length; i++) {
            address clone = _manager.clonedProtocols[protocols[i]];
            if (clone == address(0)) continue;
            try IBittyV1IntentProtocol(clone).isValidSignature(hash, signature) returns (bytes4 result) {
                if (result == 0x1626ba7e) return result;
            } catch {}
        }
        return 0xffffffff;
    }
}
