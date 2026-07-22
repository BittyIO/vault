// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IBittyV1Guard, NotRegistered, Deprecated} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {
    DisableRebalanceUntilTimestampTooEarly,
    DisableRebalanceUntilTimestampTooLong,
    RebalanceDisabled,
    SellAmountMismatch,
    BuyAmountNotEnough,
    MinimalBalanceNotMet,
    TradeSizeExceeded,
    TradeInInterval,
    TradeMustTouchStableCoin,
    TradeLimitExpired,
    TradeInvestedTotalExceeded,
    StableCoinInvestCapZero,
    InvalidLendingProtocol,
    InvalidStakingProtocol,
    InvalidAMMProtocol,
    InvalidIntentProtocol,
    InvalidValidTo,
    InvalidSwapData
} from "../interfaces/IBittyV1Manager.sol";
import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {IBittyV1LendingProtocol} from "protocol-contracts/src/interfaces/IBittyV1LendingProtocol.sol";
import {IBittyV1StakingProtocol} from "protocol-contracts/src/interfaces/IBittyV1StakingProtocol.sol";
import {IBittyV1AMMProtocol} from "protocol-contracts/src/interfaces/IBittyV1AMMProtocol.sol";
import {IBittyV1IntentProtocol, OrderNotExpired} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {
    AddressZero,
    AmountIsZero,
    InsufficientBalance,
    NotInitialized,
    AlreadyInitialized,
    AddingProtocolsDisabled
} from "../interfaces/IBittyV1Vault.sol";
import {ManagerStorage, VaultStorage, IntentOrderRecord, TradeLimit} from "./Storages.sol";
import {VaultLogic} from "./VaultLogic.sol";

library ManagerLogic {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address;
    using Clones for address;

    uint256 constant REBALANCE_DISABLE_MAX_DURATION = 4 * 365 days;

    modifier onlyInitialized(ManagerStorage storage logicStorage) {
        if (!logicStorage.isInitialized) {
            revert NotInitialized();
        }
        _;
    }

    modifier onlyNotInitialized(ManagerStorage storage logicStorage) {
        if (logicStorage.isInitialized) {
            revert AlreadyInitialized();
        }
        _;
    }

    modifier onlyAddingProtocolsEnabled(ManagerStorage storage logicStorage) {
        if (logicStorage.addingProtocolsDisabled) {
            revert AddingProtocolsDisabled();
        }
        _;
    }

    function initialize(ManagerStorage storage logicStorage, address guardAddress)
        external
        onlyNotInitialized(logicStorage)
    {
        if (guardAddress == address(0)) {
            revert AddressZero();
        }
        logicStorage.guard = IBittyV1Guard(guardAddress);
        logicStorage.isInitialized = true;
    }

    function getClone(ManagerStorage storage logicStorage, address protocol) external view returns (address) {
        return logicStorage.clonedProtocols[protocol];
    }

    function _cloneProtocol(ManagerStorage storage logicStorage, address protocol)
        private
        onlyInitialized(logicStorage)
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

    function setMinimalBalance(ManagerStorage storage logicStorage, address assetAddress, uint256 minimalBalance)
        external
        onlyInitialized(logicStorage)
    {
        if (assetAddress == address(0)) revert AddressZero();
        logicStorage.minimalBalances[assetAddress] = minimalBalance;
    }

    /**
     * @notice Set the vault's single (restricted) manager and its trade guardrail, replacing any
     * previous manager. Reverts if `stableCoinInvestCap == 0`.
     */
    function setManager(
        ManagerStorage storage logicStorage,
        address manager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt
    ) external onlyInitialized(logicStorage) {
        if (manager == address(0)) revert AddressZero();
        if (stableCoinInvestCap == 0) revert StableCoinInvestCapZero();
        logicStorage.manager = manager;
        TradeLimit storage limit = logicStorage.managerLimit;
        limit.interval = uint64(interval);
        limit.maxStableCoinPerTrade = uint64(maxStableCoinPerTrade);
        limit.stableCoinInvestCap = uint64(stableCoinInvestCap);
        limit.expiredAt = uint96(expiredAt);
        // A restricted manager: reset the tracked portfolio and any prior full-access grant.
        limit.stableCoinInvested = 0;
        limit.lastTradeTimestamp = 0;
        limit.fullAccess = false;
    }

    /**
     * @notice Set the vault's single manager as full-access: bounded only by minimal balances,
     * skipping the per-trade cap / invest cap / throttle / stablecoin-leg checks. For keys as trusted as
     * the owner. Replaces any previous manager.
     */
    function setFullManager(ManagerStorage storage logicStorage, address manager)
        external
        onlyInitialized(logicStorage)
    {
        if (manager == address(0)) revert AddressZero();
        logicStorage.manager = manager;
        delete logicStorage.managerLimit;
        logicStorage.managerLimit.fullAccess = true;
    }

    function removeManager(ManagerStorage storage logicStorage) external onlyInitialized(logicStorage) {
        logicStorage.manager = address(0);
        delete logicStorage.managerLimit;
    }

    function supply(ManagerStorage storage logicStorage, address lendingProtocol, address assetAddress, uint256 amount)
        external
        onlyInitialized(logicStorage)
    {
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
        lendingProtocol = _cloneProtocol(logicStorage, lendingProtocol);
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
        ManagerStorage storage logicStorage,
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

    function getSuppliedBalance(ManagerStorage storage logicStorage, address lendingProtocol, address assetAddress)
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

    function stake(ManagerStorage storage logicStorage, address stakingProtocol, address assetAddress, uint256 amount)
        external
        onlyInitialized(logicStorage)
    {
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
        stakingProtocol = _cloneProtocol(logicStorage, stakingProtocol);
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
        ManagerStorage storage logicStorage,
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

    function getStakedBalance(ManagerStorage storage logicStorage, address stakingProtocol, address assetAddress)
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

    function getUnstakeRequestIds(ManagerStorage storage logicStorage, address stakingProtocol)
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

    function claimUnstaked(ManagerStorage storage logicStorage, address stakingProtocol, uint256[] memory requestIds)
        external
        onlyInitialized(logicStorage)
    {
        if (requestIds.length == 0) {
            return;
        }
        stakingProtocol = logicStorage.clonedProtocols[stakingProtocol];
        if (stakingProtocol == address(0)) {
            revert InvalidStakingProtocol();
        }
        IBittyV1StakingProtocol(stakingProtocol).claimUnstaked(requestIds);
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

    function _approveNFTIfNeeded(address protocol) private {
        (bool success, bytes memory data) = protocol.staticcall(abi.encodeWithSignature("positionManager()"));
        if (!success || data.length < 32) return;
        address nft = abi.decode(data, (address));
        (bool success2, bytes memory result) =
            nft.staticcall(abi.encodeWithSignature("isApprovedForAll(address,address)", address(this), protocol));
        if (!success2 || result.length < 32) return;
        bool approved = abi.decode(result, (bool));
        if (!approved) {
            nft.functionCall(abi.encodeWithSignature("setApprovalForAll(address,bool)", protocol, true));
        }
    }

    function _addressBalance(address assetAddress) private view returns (uint256) {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        return IERC20(assetAddress).balanceOf(address(this));
    }

    /**
     * @notice The vault's total economic holding of `assetAddress`: the spot balance plus every
     * supplied (lending) and staked position denominated in the asset. So a minimal-balance reserve
     * counts assets that are earning yield, not just idle spot.
     * @dev Per-protocol views are queried through try/catch because they revert for assets a protocol
     * does not support (e.g. Lido's InvalidAsset); an unsupported/empty position contributes 0.
     */
    function _totalBalance(ManagerStorage storage logicStorage, address assetAddress)
        private
        view
        returns (uint256 total)
    {
        total = _addressBalance(assetAddress);

        uint256 lendingCount = logicStorage.lendingProtocols.length();
        for (uint256 i = 0; i < lendingCount; i++) {
            address clone = logicStorage.clonedProtocols[logicStorage.lendingProtocols.at(i)];
            if (clone == address(0)) continue;
            try IBittyV1LendingProtocol(clone).getSuppliedBalance(assetAddress) returns (uint256 supplied) {
                total += supplied;
            } catch {}
        }

        uint256 stakingCount = logicStorage.stakingProtocols.length();
        for (uint256 i = 0; i < stakingCount; i++) {
            address clone = logicStorage.clonedProtocols[logicStorage.stakingProtocols.at(i)];
            if (clone == address(0)) continue;
            try IBittyV1StakingProtocol(clone).getStakedBalance(assetAddress) returns (uint256 staked) {
                total += staked;
            } catch {}
        }
    }

    function _checkAMMProtocol(ManagerStorage storage logicStorage, address ammProtocol) private view {
        if (!logicStorage.ammProtocols.contains(ammProtocol)) {
            revert InvalidAMMProtocol();
        }
        if (
            !logicStorage.guard.isAMMProtocolRegistered(ammProtocol)
                && !logicStorage.guard.isAMMProtocolDeprecated(ammProtocol)
        ) {
            revert NotRegistered();
        }
    }

    function _checkRebalanceDisabledUntilTimestamp(ManagerStorage storage logicStorage) private view {
        if (
            logicStorage.rebalanceDisabledUntilTimestamp > 0
                && block.timestamp < logicStorage.rebalanceDisabledUntilTimestamp
        ) {
            revert RebalanceDisabled();
        }
    }

    /**
     * @notice Shared gate for every asset-manager trade (market/limit/TWAP).
     * @dev `sellAmount` is the amount of `from` leaving the vault and `toAmount` the amount of `to`
     * coming back (a floor for exact-in trades, exact for exact-out). The sell leg (`from`) may be
     * any token the vault holds — it need not be on the vault asset allowlist (e.g. airdrops or
     * mistaken transfers can still be sold out). The buy leg (`to`) must remain an allowlisted asset
     * or stablecoin. Enforces, per manager (keyed by msg.sender, preserved through
     * delegatecall): a stablecoin size cap and a frequency throttle. The size cap is denominated in
     * stablecoin whole tokens, so when it is set the trade must have a stablecoin as either leg; the
     * stablecoin leg's amount is measured against the cap.
     * `stableCoinInvested` (the manager's deployed portfolio) rises by the stablecoin spent on
     * stable→asset trades and falls when assets are sold back, and may never exceed `stableCoinInvestCap`.
     * `expiredAt` blocks all trades once reached (0 = no expiry). Every caller here holds
     * ASSET_MANAGER_ROLE and is always enforced, so an unconfigured cap of 0 blocks stable→asset
     * investing rather than allowing it.
     */
    function _validateTrade(
        ManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address from,
        address to,
        uint256 sellAmount,
        uint256 toAmount,
        bool creditReturn
    ) private {
        VaultLogic.checkAsset(vaultStorage, to);
        _checkRebalanceDisabledUntilTimestamp(logicStorage);

        uint256 minBal = logicStorage.minimalBalances[from];
        // Tokens already promised to open limit/TWAP orders are still on-chain but not free to sell, so
        // measure against balance minus that reservation, not the raw balance.
        uint256 committed = logicStorage.committedIntentSell[from];
        if (minBal > 0 || committed > 0) {
            uint256 bal = _totalBalance(logicStorage, from);
            uint256 available = bal > committed ? bal - committed : 0;
            if (available < sellAmount || available - sellAmount < minBal) revert MinimalBalanceNotMet();
        }

        TradeLimit storage limit = logicStorage.managerLimit;

        // Full-access managers are bounded only by the minimal-balance floor above; skip the entire trade
        // limit — including the stablecoin-leg requirement — so they may trade any asset (even asset ->
        // asset) freely and without the per-trade cap/invest/throttle accounting.
        if (limit.fullAccess) return;

        // Restricted managers must touch a stablecoin (the caps are denominated in stablecoin whole tokens).
        if (!vaultStorage.stableCoins.contains(from) && !vaultStorage.stableCoins.contains(to)) {
            revert TradeMustTouchStableCoin();
        }

        if (limit.expiredAt != 0 && block.timestamp >= limit.expiredAt) {
            revert TradeLimitExpired();
        }

        uint256 maxWholeTokens = limit.maxStableCoinPerTrade;
        if (maxWholeTokens != 0) {
            address stableCoin;
            uint256 stableAmount;
            if (vaultStorage.stableCoins.contains(from)) {
                stableCoin = from;
                stableAmount = sellAmount;
            } else if (vaultStorage.stableCoins.contains(to)) {
                stableCoin = to;
                stableAmount = toAmount;
            }
            uint256 maxUnits = maxWholeTokens * (10 ** IERC20Metadata(stableCoin).decimals());
            if (stableAmount > maxUnits) revert TradeSizeExceeded();
        }

        uint256 cap = limit.stableCoinInvestCap;
        if (vaultStorage.stableCoins.contains(from)) {
            // Stablecoin leaving the vault. Count it (whole tokens, rounded UP so a stream of
            // sub-whole-token trades cannot dodge the cap). For a stablecoin-for-stablecoin trade count
            // the LARGER of the two legs — this caps how much a manager can churn through (possibly
            // manipulated) stable pools regardless of trade direction/rate; without it, repeated
            // stable->stable trades could bleed the vault unchecked.
            uint256 fromUnit = 10 ** IERC20Metadata(from).decimals();
            uint256 wholeSpent = (sellAmount + fromUnit - 1) / fromUnit;
            if (vaultStorage.stableCoins.contains(to)) {
                uint256 toUnit = 10 ** IERC20Metadata(to).decimals();
                uint256 toWhole = (toAmount + toUnit - 1) / toUnit;
                if (toWhole > wholeSpent) wholeSpent = toWhole;
            }
            uint256 invested = uint256(limit.stableCoinInvested) + wholeSpent;
            if (invested > cap) revert TradeInvestedTotalExceeded();
            limit.stableCoinInvested = uint64(invested);
        } else if (vaultStorage.stableCoins.contains(to) && creditReturn) {
            // Divesting (asset -> stable) via a SYNCHRONOUS market trade: credit the stablecoin coming
            // back (floored, conservative). Async intent orders do not credit here — there is no fill
            // hook, so a placed-then-cancelled buy-stablecoin order must not be able to reduce the
            // invested total. Freeing the cap therefore requires an actually-settled (market) divest.
            uint256 unit = 10 ** IERC20Metadata(to).decimals();
            uint256 wholeReceived = toAmount / unit;
            uint256 invested = limit.stableCoinInvested;
            limit.stableCoinInvested = uint64(invested > wholeReceived ? invested - wholeReceived : 0);
        }

        if (limit.interval != 0) {
            uint256 last = limit.lastTradeTimestamp;
            if (last != 0 && block.timestamp - last < limit.interval) revert TradeInInterval();
            limit.lastTradeTimestamp = uint128(block.timestamp);
        }
    }

    function addLiquidity(
        ManagerStorage storage logicStorage,
        address ammProtocol,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external onlyInitialized(logicStorage) {
        _checkAMMProtocol(logicStorage, ammProtocol);
        if (logicStorage.guard.isAMMProtocolDeprecated(ammProtocol)) revert Deprecated();
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

    function removeLiquidity(ManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) revert InvalidAMMProtocol();
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).removeLiquidity(data);
    }

    function decreaseLiquidity(ManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) revert InvalidAMMProtocol();
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).decreaseLiquidity(data);
    }

    function claimAMMFees(ManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) revert InvalidAMMProtocol();
        _approveNFTIfNeeded(clone);
        IBittyV1AMMProtocol(clone).claimAMMFees(data);
    }

    /**
     * @notice Asset-manager rebalance: sell exactly `sellAmount` of `from` for ≥ `buyAmountMin` of
     * `to`, back into the vault. Subject to the rebalance guards (rebalance-disabled + minimal balance).
     */
    function marketSell(
        ManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address ammProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external onlyInitialized(logicStorage) {
        _checkAMMProtocol(logicStorage, ammProtocol);
        if (logicStorage.guard.isAMMProtocolDeprecated(ammProtocol)) revert Deprecated();
        _validateTrade(logicStorage, vaultStorage, from, to, sellAmount, buyAmountMin, true);
        _swapExactIn(logicStorage, ammProtocol, from, sellAmount, to, buyAmountMin, address(this), data);
    }

    /**
     * @notice Asset-manager rebalance: buy exactly `buyAmount` of `to` for ≤ `sellAmountMax` of `from`,
     * back into the vault. Subject to the rebalance guards (rebalance-disabled + minimal balance).
     */
    function marketBuy(
        ManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address ammProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        bytes memory data
    ) external onlyInitialized(logicStorage) {
        _checkAMMProtocol(logicStorage, ammProtocol);
        if (logicStorage.guard.isAMMProtocolDeprecated(ammProtocol)) revert Deprecated();
        _validateTrade(logicStorage, vaultStorage, from, to, sellAmountMax, buyAmount, true);
        _swapExactOut(logicStorage, ammProtocol, from, sellAmountMax, to, buyAmount, address(this), data);
    }

    function _swapExactIn(
        ManagerStorage storage logicStorage,
        address ammProtocol,
        address sellAssetAddress,
        uint256 sellAmount,
        address toAssetAddress,
        uint256 buyAmountMin,
        address recipient,
        bytes memory data
    ) private {
        if (sellAmount == 0 || buyAmountMin == 0) revert AmountIsZero();
        (address sellToken_, uint256 sellAmount_, address buyToken_, uint256 buyAmountMin_) =
            abi.decode(data, (address, uint256, address, uint256));
        if (
            sellToken_ != sellAssetAddress || sellAmount_ != sellAmount || buyToken_ != toAssetAddress
                || buyAmountMin_ != buyAmountMin
        ) revert InvalidSwapData();

        uint256 sellAssetBalanceBefore = _addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore < sellAmount) revert InsufficientBalance();

        uint256 recipientBuyBalanceBefore = IERC20(toAssetAddress).balanceOf(recipient);

        ammProtocol = _cloneProtocol(logicStorage, ammProtocol);
        if (IERC20(sellAssetAddress).allowance(address(this), ammProtocol) < sellAmount) {
            IERC20(sellAssetAddress).forceApprove(ammProtocol, type(uint256).max);
        }
        IBittyV1AMMProtocol(ammProtocol).swap(data, recipient);

        // Guard against the AMM pulling more than the authorized sellAmount. A slightly-higher
        // ending balance is fine and expected: protocols can refund dust ETH to the vault, which
        // receive() wraps into WETH (matches _swapExactOut's over-spend check below).
        if (sellAssetBalanceBefore - _addressBalance(sellAssetAddress) > sellAmount) revert SellAmountMismatch();
        if (IERC20(toAssetAddress).balanceOf(recipient) - recipientBuyBalanceBefore < buyAmountMin) {
            revert BuyAmountNotEnough();
        }
    }

    function _swapExactOut(
        ManagerStorage storage logicStorage,
        address ammProtocol,
        address sellAssetAddress,
        uint256 sellAmountMax,
        address toAssetAddress,
        uint256 buyAmount,
        address recipient,
        bytes memory data
    ) private {
        if (buyAmount == 0 || sellAmountMax == 0) revert AmountIsZero();
        (address sellToken_, uint256 sellAmountMax_, address buyToken_, uint256 buyAmount_) =
            abi.decode(data, (address, uint256, address, uint256));
        if (
            sellToken_ != sellAssetAddress || sellAmountMax_ != sellAmountMax || buyToken_ != toAssetAddress
                || buyAmount_ != buyAmount
        ) revert InvalidSwapData();

        uint256 sellAssetBalanceBefore = _addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore < sellAmountMax) revert InsufficientBalance();

        uint256 recipientBuyBalanceBefore = IERC20(toAssetAddress).balanceOf(recipient);

        ammProtocol = _cloneProtocol(logicStorage, ammProtocol);
        if (IERC20(sellAssetAddress).allowance(address(this), ammProtocol) < sellAmountMax) {
            IERC20(sellAssetAddress).forceApprove(ammProtocol, type(uint256).max);
        }
        IBittyV1AMMProtocol(ammProtocol).swapExactOut(data, recipient);

        if (sellAssetBalanceBefore - _addressBalance(sellAssetAddress) > sellAmountMax) revert SellAmountMismatch();
        if (IERC20(toAssetAddress).balanceOf(recipient) - recipientBuyBalanceBefore < buyAmount) {
            revert BuyAmountNotEnough();
        }
    }

    function disableRebalanceUntilTimestamp(ManagerStorage storage logicStorage, uint256 timestamp)
        external
        onlyInitialized(logicStorage)
    {
        if (timestamp == 0) {
            return;
        }
        if (timestamp < logicStorage.rebalanceDisabledUntilTimestamp) {
            revert DisableRebalanceUntilTimestampTooEarly();
        }
        if (timestamp > block.timestamp + REBALANCE_DISABLE_MAX_DURATION) {
            revert DisableRebalanceUntilTimestampTooLong();
        }
        logicStorage.rebalanceDisabledUntilTimestamp = uint64(timestamp);
    }

    function disableAddingProtocols(ManagerStorage storage logicStorage) external onlyInitialized(logicStorage) {
        logicStorage.addingProtocolsDisabled = true;
    }

    function addLendingProtocols(ManagerStorage storage logicStorage, address[] memory lendingProtocolAddresses)
        external
        onlyAddingProtocolsEnabled(logicStorage)
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < lendingProtocolAddresses.length; i++) {
            if (!logicStorage.guard.isLendingProtocolRegistered(lendingProtocolAddresses[i])) {
                revert NotRegistered();
            }
            logicStorage.lendingProtocols.add(lendingProtocolAddresses[i]);
        }
    }

    function addStakingProtocols(ManagerStorage storage logicStorage, address[] memory stakingProtocolAddresses)
        external
        onlyAddingProtocolsEnabled(logicStorage)
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < stakingProtocolAddresses.length; i++) {
            if (!logicStorage.guard.isStakingProtocolRegistered(stakingProtocolAddresses[i])) {
                revert NotRegistered();
            }
            logicStorage.stakingProtocols.add(stakingProtocolAddresses[i]);
        }
    }

    function removeLendingProtocols(ManagerStorage storage logicStorage, address[] memory lendingProtocolAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < lendingProtocolAddresses.length; i++) {
            logicStorage.lendingProtocols.remove(lendingProtocolAddresses[i]);
        }
    }

    function removeStakingProtocols(ManagerStorage storage logicStorage, address[] memory stakingProtocolAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < stakingProtocolAddresses.length; i++) {
            logicStorage.stakingProtocols.remove(stakingProtocolAddresses[i]);
        }
    }

    function addAMMProtocols(ManagerStorage storage logicStorage, address[] memory ammProtocolAddresses)
        external
        onlyAddingProtocolsEnabled(logicStorage)
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < ammProtocolAddresses.length; i++) {
            if (!logicStorage.guard.isAMMProtocolRegistered(ammProtocolAddresses[i])) {
                revert NotRegistered();
            }
            logicStorage.ammProtocols.add(ammProtocolAddresses[i]);
        }
    }

    function removeAMMProtocols(ManagerStorage storage logicStorage, address[] memory ammProtocolAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < ammProtocolAddresses.length; i++) {
            logicStorage.ammProtocols.remove(ammProtocolAddresses[i]);
        }
    }

    function getLendingProtocols(ManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.lendingProtocols.values();
    }

    function getStakingProtocols(ManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.stakingProtocols.values();
    }

    function getAMMProtocols(ManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.ammProtocols.values();
    }

    function getLiquidity(ManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        view
        returns (uint256)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) return 0;
        return IBittyV1AMMProtocol(clone).getLiquidity(data);
    }

    // ============ Intent protocols ============

    function _checkIntentProtocol(ManagerStorage storage logicStorage, address intentProtocol) private view {
        if (!logicStorage.intentProtocols.contains(intentProtocol)) revert InvalidIntentProtocol();
        if (logicStorage.guard.isIntentProtocolDeprecated(intentProtocol)) revert Deprecated();
        if (!logicStorage.guard.isIntentProtocolRegistered(intentProtocol)) revert NotRegistered();
    }

    function _executeCancel(ManagerStorage storage logicStorage, address intentProtocol, bytes32 orderId) private {
        address clone = logicStorage.clonedProtocols[intentProtocol];
        IBittyV1IntentProtocol.CancelInstructions memory instr =
            IBittyV1IntentProtocol(clone).buildCancelInstructions(orderId);
        if (instr.cancelTarget != address(0)) {
            instr.cancelTarget.functionCall(instr.cancelCalldata);
        }
        IntentOrderRecord memory record = logicStorage.intentOrderRecords[orderId];
        if (record.reservedSell > 0) {
            uint256 c = logicStorage.committedIntentSell[record.sellToken];
            logicStorage.committedIntentSell[record.sellToken] = c > record.reservedSell ? c - record.reservedSell : 0;
        }
        delete logicStorage.intentOrderRecords[orderId];
    }

    function limitSell(
        ManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address intentProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        uint32 validTo
    ) external onlyInitialized(logicStorage) returns (bytes32 orderId) {
        _checkIntentProtocol(logicStorage, intentProtocol);
        _validateTrade(logicStorage, vaultStorage, from, to, sellAmount, buyAmountMin, false);
        orderId = _intentTrade(logicStorage, intentProtocol, from, sellAmount, to, buyAmountMin, validTo, true);
    }

    function limitBuy(
        ManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address intentProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        uint32 validTo
    ) external onlyInitialized(logicStorage) returns (bytes32 orderId) {
        _checkIntentProtocol(logicStorage, intentProtocol);
        _validateTrade(logicStorage, vaultStorage, from, to, sellAmountMax, buyAmount, false);
        orderId = _intentTrade(logicStorage, intentProtocol, from, sellAmountMax, to, buyAmount, validTo, false);
    }

    function _intentTrade(
        ManagerStorage storage logicStorage,
        address intentProtocol,
        address sellAssetAddress,
        uint256 sellAmount,
        address toAssetAddress,
        uint256 buyAmountMin,
        uint32 validTo,
        bool isSellOrder
    ) private returns (bytes32 orderId) {
        if (sellAmount == 0 || buyAmountMin == 0) revert AmountIsZero();
        if (validTo <= block.timestamp) revert InvalidValidTo();

        address clone = _cloneProtocol(logicStorage, intentProtocol);
        bytes memory data = abi.encode(sellAssetAddress, sellAmount, toAssetAddress, buyAmountMin, validTo, isSellOrder);

        IBittyV1IntentProtocol.OrderInstructions memory instr =
            IBittyV1IntentProtocol(clone).buildLimitOrderInstructions(data, address(this));
        orderId = instr.orderId;

        if (instr.registerTarget != address(0)) {
            instr.registerTarget.functionCall(instr.registerCalldata);
        }

        if (
            instr.approveTarget != address(0) && instr.sellAmount > 0
                && IERC20(instr.sellToken).allowance(address(this), instr.approveTarget) < instr.sellAmount
        ) {
            IERC20(instr.sellToken).forceApprove(instr.approveTarget, type(uint256).max);
        }

        logicStorage.intentOrderRecords[orderId] =
            IntentOrderRecord({sellToken: instr.sellToken, expiresAt: uint96(validTo), reservedSell: sellAmount});
        logicStorage.committedIntentSell[instr.sellToken] += sellAmount;

        emit IBittyV1IntentProtocol.OrderCreated(orderId, address(this));
    }

    function cancelLimitOrder(ManagerStorage storage logicStorage, address intentProtocol, bytes memory data)
        external
        onlyInitialized(logicStorage)
    {
        if (logicStorage.clonedProtocols[intentProtocol] == address(0)) revert InvalidIntentProtocol();

        bytes32 orderId = abi.decode(data, (bytes32));
        if (logicStorage.intentOrderRecords[orderId].sellToken == address(0)) revert InvalidIntentProtocol();

        _executeCancel(logicStorage, intentProtocol, orderId);
        emit IBittyV1IntentProtocol.OrderCancelled(orderId, address(this));
    }

    /**
     * @notice Permissionless cleanup of expired limit orders (does not affect TWAP orders).
     *         Reverts if any order is still live.
     * @dev Also releases each order's committedIntentSell reservation. A filled-but-not-yet-expired
     *      order still holds its reservation (settlement gives no on-chain callback), so until this runs
     *      the vault under-reports sellable balance for that token and may block otherwise-valid new
     *      orders. Keepers should call this promptly once orders expire to free the reservation.
     */
    function cleanExpiredLimitOrders(
        ManagerStorage storage logicStorage,
        address intentProtocol,
        bytes32[] calldata orderDigests
    ) external onlyInitialized(logicStorage) {
        if (logicStorage.clonedProtocols[intentProtocol] == address(0)) {
            revert InvalidIntentProtocol();
        }

        for (uint256 i = 0; i < orderDigests.length; i++) {
            bytes32 orderId = orderDigests[i];
            IntentOrderRecord memory record = logicStorage.intentOrderRecords[orderId];
            if (record.expiresAt == 0 || block.timestamp <= record.expiresAt) revert OrderNotExpired();
            _executeCancel(logicStorage, intentProtocol, orderId);
        }
    }

    function addIntentProtocols(ManagerStorage storage logicStorage, address[] memory intentProtocolAddresses)
        external
        onlyAddingProtocolsEnabled(logicStorage)
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < intentProtocolAddresses.length; i++) {
            if (!logicStorage.guard.isIntentProtocolRegistered(intentProtocolAddresses[i])) revert NotRegistered();
            logicStorage.intentProtocols.add(intentProtocolAddresses[i]);
        }
    }

    function removeIntentProtocols(ManagerStorage storage logicStorage, address[] memory intentProtocolAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < intentProtocolAddresses.length; i++) {
            logicStorage.intentProtocols.remove(intentProtocolAddresses[i]);
        }
    }

    function getIntentProtocols(ManagerStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.intentProtocols.values();
    }

    function twapSell(
        ManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address intentProtocol,
        address from,
        address to,
        uint256 totalSellAmount,
        uint256 minPartLimit,
        uint256 n,
        uint256 partDuration,
        uint256 span
    ) external onlyInitialized(logicStorage) returns (bytes32 twapId) {
        _checkIntentProtocol(logicStorage, intentProtocol);
        if (totalSellAmount == 0 || minPartLimit == 0 || n == 0 || partDuration == 0) revert AmountIsZero();
        _validateTrade(logicStorage, vaultStorage, from, to, totalSellAmount, minPartLimit * n, false);

        address clone = _cloneProtocol(logicStorage, intentProtocol);
        bytes memory data = abi.encode(from, totalSellAmount, to, minPartLimit, n, partDuration, span);

        (IBittyV1IntentProtocol.OrderInstructions memory instr, uint256 expiresAt_) =
            IBittyV1IntentProtocol(clone).buildTwapInstructions(data);
        twapId = instr.orderId;

        if (instr.registerTarget != address(0)) {
            instr.registerTarget.functionCall(instr.registerCalldata);
        }

        if (
            instr.approveTarget != address(0) && instr.sellAmount > 0
                && IERC20(instr.sellToken).allowance(address(this), instr.approveTarget) < instr.sellAmount
        ) {
            IERC20(instr.sellToken).forceApprove(instr.approveTarget, type(uint256).max);
        }

        logicStorage.intentOrderRecords[twapId] = IntentOrderRecord({
            sellToken: instr.sellToken, expiresAt: uint96(expiresAt_), reservedSell: totalSellAmount
        });
        logicStorage.committedIntentSell[instr.sellToken] += totalSellAmount;

        emit IBittyV1IntentProtocol.TwapCreated(twapId, address(this));
    }

    function twapBuy(
        ManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address intentProtocol,
        address from,
        address to,
        uint256 totalBuyAmount,
        uint256 sellAmountPerPart,
        uint256 n,
        uint256 partDuration,
        uint256 span
    ) external onlyInitialized(logicStorage) returns (bytes32 twapId) {
        _checkIntentProtocol(logicStorage, intentProtocol);
        if (totalBuyAmount == 0 || sellAmountPerPart == 0 || n == 0 || partDuration == 0) revert AmountIsZero();
        uint256 minPartLimit = totalBuyAmount / n;
        if (minPartLimit == 0) revert AmountIsZero();
        uint256 totalSellAmount = sellAmountPerPart * n;
        _validateTrade(logicStorage, vaultStorage, from, to, totalSellAmount, totalBuyAmount, false);

        address clone = _cloneProtocol(logicStorage, intentProtocol);
        bytes memory data = abi.encode(from, totalSellAmount, to, minPartLimit, n, partDuration, span);

        (IBittyV1IntentProtocol.OrderInstructions memory instr, uint256 expiresAt_) =
            IBittyV1IntentProtocol(clone).buildTwapInstructions(data);
        twapId = instr.orderId;

        if (instr.registerTarget != address(0)) {
            instr.registerTarget.functionCall(instr.registerCalldata);
        }

        if (
            instr.approveTarget != address(0) && instr.sellAmount > 0
                && IERC20(instr.sellToken).allowance(address(this), instr.approveTarget) < instr.sellAmount
        ) {
            IERC20(instr.sellToken).forceApprove(instr.approveTarget, type(uint256).max);
        }

        logicStorage.intentOrderRecords[twapId] = IntentOrderRecord({
            sellToken: instr.sellToken, expiresAt: uint96(expiresAt_), reservedSell: totalSellAmount
        });
        logicStorage.committedIntentSell[instr.sellToken] += totalSellAmount;

        emit IBittyV1IntentProtocol.TwapCreated(twapId, address(this));
    }

    function cancelTwapOrder(ManagerStorage storage logicStorage, address intentProtocol, bytes32 twapId)
        external
        onlyInitialized(logicStorage)
    {
        IntentOrderRecord memory record = logicStorage.intentOrderRecords[twapId];
        if (record.sellToken == address(0)) revert InvalidIntentProtocol();

        _executeCancel(logicStorage, intentProtocol, twapId);

        emit IBittyV1IntentProtocol.TwapCancelled(twapId, address(this));
    }
}
