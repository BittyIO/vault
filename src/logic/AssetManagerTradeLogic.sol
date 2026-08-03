// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {NotRegistered, Deprecated} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {
    DisableRebalanceUntilTimestampTooEarly,
    DisableRebalanceUntilTimestampTooLong,
    RebalanceDisabled,
    MinimalBalanceNotMet,
    TradeSizeExceeded,
    TradeInInterval,
    TradeMustTouchStableCoin,
    TradeLimitExpired,
    TradeInvestedTotalExceeded,
    InvalidAMMProtocol,
    InvalidIntentProtocol,
    IntentProtocolMismatch,
    InvalidValidTo
} from "../interfaces/IBittyV1AssetManager.sol";
import {IBittyV1LendingProtocol} from "protocol-contracts/src/interfaces/IBittyV1LendingProtocol.sol";
import {IBittyV1StakingProtocol} from "protocol-contracts/src/interfaces/IBittyV1StakingProtocol.sol";
import {IBittyV1AMMProtocol} from "protocol-contracts/src/interfaces/IBittyV1AMMProtocol.sol";
import {IBittyV1IntentProtocol, OrderNotExpired} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {AmountIsZero, NotInitialized} from "../interfaces/IBittyV1Vault.sol";
import {AssetManagerStorage, VaultStorage, IntentOrderRecord, AssetManagerSettings} from "./Storages.sol";
import {VaultLogic} from "./VaultLogic.sol";
import {AssetManagerShared} from "./AssetManagerShared.sol";

/**
 * @title AssetManagerTradeLogic
 * @notice The asset manager's trading surface — AMM liquidity, and intent (limit / TWAP) orders.
 *         Trading is intent-only (no direct AMM market swaps): CoW-style batch settlement is MEV/
 *         sandwich-resistant, so a compromised key cannot atomically sandwich its own swap to drain the
 *         vault. Split out of {AssetManagerLogic} (which keeps yield + config + protocol registration)
 *         so each deployed library stays under the EIP-170 24,576-byte limit. Shares
 *         {AssetManagerShared} for clone + balance helpers; operates on the same {AssetManagerStorage}.
 */
library AssetManagerTradeLogic {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address;

    uint256 constant REBALANCE_DISABLE_MAX_DURATION = 4 * 365 days;

    modifier onlyInitialized(AssetManagerStorage storage logicStorage) {
        if (!logicStorage.isInitialized) {
            revert NotInitialized();
        }
        _;
    }

    /**
     * @notice The vault's total economic holding of `assetAddress`: the spot balance plus every
     * supplied (lending) and staked position denominated in the asset. So a minimal-balance reserve
     * counts assets that are earning yield, not just idle spot.
     * @dev Per-protocol views are queried through try/catch because they revert for assets a protocol
     * does not support (e.g. Lido's InvalidAsset); an unsupported/empty position contributes 0.
     */
    function _totalBalance(AssetManagerStorage storage logicStorage, address assetAddress)
        private
        view
        returns (uint256 total)
    {
        total = AssetManagerShared.addressBalance(assetAddress);

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

    function _checkAMMProtocol(AssetManagerStorage storage logicStorage, address ammProtocol) private view {
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

    function _checkRebalanceDisabledUntilTimestamp(AssetManagerStorage storage logicStorage) private view {
        if (
            logicStorage.rebalanceDisabledUntilTimestamp > 0
                && block.timestamp < logicStorage.rebalanceDisabledUntilTimestamp
        ) {
            revert RebalanceDisabled();
        }
    }

    /**
     * @notice Shared gate for every asset manager trade (market/limit/TWAP).
     * @dev `sellAmount` is the amount of `from` leaving the vault and `toAmount` the amount of `to`
     * coming back (a floor for exact-in trades, exact for exact-out). The sell leg (`from`) may be
     * any token the vault holds — it need not be on the vault asset allowlist (e.g. airdrops or
     * mistaken transfers can still be sold out). The buy leg (`to`) must remain an allowlisted asset
     * or stablecoin. Enforces, per asset manager (keyed by msg.sender, preserved through
     * delegatecall): a stablecoin size cap and a frequency throttle. The size cap is denominated in
     * stablecoin whole tokens, so when it is set the trade must have a stablecoin as either leg; the
     * stablecoin leg's amount is measured against the cap.
     * `stableCoinInvested` (the asset manager's deployed portfolio) rises by the stablecoin spent on
     * stable→asset trades and may never exceed `stableCoinInvestCap`. Trading is intent-only (CoW-style
     * limit/TWAP), which settles asynchronously with no fill hook, so a divest (asset→stable) cannot
     * safely credit the invested total back (a placed-then-cancelled buy-stablecoin order would otherwise
     * free the cap for free). The invest cap is therefore a lifetime ceiling on restricted deployment;
     * raise it via {setAssetManager} (or use a full-access manager) to redeploy. `expiredAt` blocks all
     * trades once reached (0 = no expiry). An unconfigured cap of 0 blocks stable→asset investing.
     */
    /// @return investedDelta the whole-token stablecoin this trade added to `stableCoinInvested` (0 unless
    ///         it was a restricted stable→asset/stable→stable invest); stored on the order record so an
    ///         unfilled cancel/expiry can refund it.
    function _validateTrade(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address from,
        address to,
        uint256 sellAmount,
        uint256 toAmount
    ) private returns (uint64 investedDelta) {
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

        AssetManagerSettings storage settings = logicStorage.assetManagerSettings;

        // Full-access asset managers are bounded only by the minimal-balance floor above; skip the entire trade
        // limit — including the stablecoin-leg requirement — so they may trade any asset (even asset ->
        // asset) freely and without the per-trade cap/invest/throttle accounting.
        if (settings.fullAccess) return 0;

        // Restricted asset managers must touch a stablecoin (the caps are denominated in stablecoin whole tokens).
        if (!vaultStorage.stableCoins.contains(from) && !vaultStorage.stableCoins.contains(to)) {
            revert TradeMustTouchStableCoin();
        }

        if (settings.expiredAt != 0 && block.timestamp >= settings.expiredAt) {
            revert TradeLimitExpired();
        }

        uint256 maxWholeTokens = settings.maxStableCoinPerTrade;
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

        uint256 cap = settings.stableCoinInvestCap;
        if (vaultStorage.stableCoins.contains(from)) {
            // Stablecoin leaving the vault. Count it (whole tokens, rounded UP so a stream of
            // sub-whole-token trades cannot dodge the cap). For a stablecoin-for-stablecoin trade count
            // the LARGER of the two legs — this caps how much a asset manager can churn through (possibly
            // manipulated) stable pools regardless of trade direction/rate; without it, repeated
            // stable->stable trades could bleed the vault unchecked.
            uint256 fromUnit = 10 ** IERC20Metadata(from).decimals();
            uint256 wholeSpent = (sellAmount + fromUnit - 1) / fromUnit;
            if (vaultStorage.stableCoins.contains(to)) {
                uint256 toUnit = 10 ** IERC20Metadata(to).decimals();
                uint256 toWhole = (toAmount + toUnit - 1) / toUnit;
                if (toWhole > wholeSpent) wholeSpent = toWhole;
            }
            uint256 invested = uint256(settings.stableCoinInvested) + wholeSpent;
            if (invested > cap) revert TradeInvestedTotalExceeded();
            settings.stableCoinInvested = uint64(invested);
            investedDelta = uint64(wholeSpent);
        }

        if (settings.interval != 0) {
            uint256 last = settings.lastTradeTimestamp;
            if (last != 0 && block.timestamp - last < settings.interval) revert TradeInInterval();
            settings.lastTradeTimestamp = uint128(block.timestamp);
        }
    }

    // ============ AMM liquidity ============

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
        if (logicStorage.guard.isAMMProtocolDeprecated(ammProtocol)) revert Deprecated();

        VaultLogic.checkAsset(vaultStorage, token0);
        VaultLogic.checkAsset(vaultStorage, token1);

        address clone = AssetManagerShared.cloneProtocol(logicStorage, ammProtocol);
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

    function getLiquidity(AssetManagerStorage storage logicStorage, address ammProtocol, bytes memory data)
        external
        view
        returns (uint256)
    {
        address clone = logicStorage.clonedProtocols[ammProtocol];
        if (clone == address(0)) return 0;
        return IBittyV1AMMProtocol(clone).getLiquidity(data);
    }

    function disableRebalanceUntilTimestamp(AssetManagerStorage storage logicStorage, uint256 timestamp)
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

    // ============ Intent protocols (limit + TWAP) ============

    function _checkIntentProtocol(AssetManagerStorage storage logicStorage, address intentProtocol) private view {
        if (!logicStorage.intentProtocols.contains(intentProtocol)) revert InvalidIntentProtocol();
        if (logicStorage.guard.isIntentProtocolDeprecated(intentProtocol)) revert Deprecated();
        if (!logicStorage.guard.isIntentProtocolRegistered(intentProtocol)) revert NotRegistered();
    }

    function _executeCancel(AssetManagerStorage storage logicStorage, address intentProtocol, bytes32 orderId) private {
        IntentOrderRecord memory record = logicStorage.intentOrderRecords[orderId];
        if (record.owningProtocol != intentProtocol) revert IntentProtocolMismatch();
        address clone = logicStorage.clonedProtocols[intentProtocol];

        // Refund the invest-cap budget for an order that never filled — read BEFORE invalidating, which
        // overwrites the settlement's filledAmount with a sentinel. Fill-or-kill orders are all-or-nothing,
        // so an unfilled order deployed nothing; a filled one stays counted. Only restricted stable-invest
        // limit orders carry a non-zero investedCounted (divests, full-access, and TWAPs carry 0).
        if (record.investedCounted > 0 && !IBittyV1IntentProtocol(clone).orderFilled(orderId)) {
            AssetManagerSettings storage settings = logicStorage.assetManagerSettings;
            uint64 inv = settings.stableCoinInvested;
            settings.stableCoinInvested = inv > record.investedCounted ? inv - record.investedCounted : 0;
        }

        IBittyV1IntentProtocol.CancelInstructions memory instr =
            IBittyV1IntentProtocol(clone).buildCancelInstructions(orderId);
        if (instr.cancelTarget != address(0)) {
            instr.cancelTarget.functionCall(instr.cancelCalldata);
        }
        if (record.reservedSell > 0) {
            uint256 c = logicStorage.committedIntentSell[record.sellToken];
            logicStorage.committedIntentSell[record.sellToken] = c > record.reservedSell ? c - record.reservedSell : 0;
        }
        delete logicStorage.intentOrderRecords[orderId];
    }

    function limitSell(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address intentProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        uint32 validTo
    ) external onlyInitialized(logicStorage) returns (bytes32 orderId) {
        _checkIntentProtocol(logicStorage, intentProtocol);
        uint64 invested = _validateTrade(logicStorage, vaultStorage, from, to, sellAmount, buyAmountMin);
        orderId =
            _intentTrade(logicStorage, intentProtocol, from, sellAmount, to, buyAmountMin, validTo, true, invested);
    }

    function limitBuy(
        AssetManagerStorage storage logicStorage,
        VaultStorage storage vaultStorage,
        address intentProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        uint32 validTo
    ) external onlyInitialized(logicStorage) returns (bytes32 orderId) {
        _checkIntentProtocol(logicStorage, intentProtocol);
        uint64 invested = _validateTrade(logicStorage, vaultStorage, from, to, sellAmountMax, buyAmount);
        orderId =
            _intentTrade(logicStorage, intentProtocol, from, sellAmountMax, to, buyAmount, validTo, false, invested);
    }

    function _intentTrade(
        AssetManagerStorage storage logicStorage,
        address intentProtocol,
        address sellAssetAddress,
        uint256 sellAmount,
        address toAssetAddress,
        uint256 buyAmountMin,
        uint32 validTo,
        bool isSellOrder,
        uint64 investedCounted
    ) private returns (bytes32 orderId) {
        if (sellAmount == 0 || buyAmountMin == 0) revert AmountIsZero();
        if (validTo <= block.timestamp) revert InvalidValidTo();

        address clone = AssetManagerShared.cloneProtocol(logicStorage, intentProtocol);
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

        logicStorage.intentOrderRecords[orderId] = IntentOrderRecord({
            sellToken: instr.sellToken,
            expiresAt: uint96(validTo),
            owningProtocol: intentProtocol,
            investedCounted: investedCounted,
            reservedSell: sellAmount
        });
        logicStorage.committedIntentSell[instr.sellToken] += sellAmount;

        emit IBittyV1IntentProtocol.OrderCreated(orderId, address(this));
    }

    function cancelLimitOrder(AssetManagerStorage storage logicStorage, address intentProtocol, bytes memory data)
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
        AssetManagerStorage storage logicStorage,
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

    function twapSell(
        AssetManagerStorage storage logicStorage,
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
        _validateTrade(logicStorage, vaultStorage, from, to, totalSellAmount, minPartLimit * n);

        address clone = AssetManagerShared.cloneProtocol(logicStorage, intentProtocol);
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
            sellToken: instr.sellToken,
            expiresAt: uint96(expiresAt_),
            owningProtocol: intentProtocol,
            investedCounted: 0,
            reservedSell: totalSellAmount
        });
        logicStorage.committedIntentSell[instr.sellToken] += totalSellAmount;

        emit IBittyV1IntentProtocol.TwapCreated(twapId, address(this));
    }

    function twapBuy(
        AssetManagerStorage storage logicStorage,
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
        _validateTrade(logicStorage, vaultStorage, from, to, totalSellAmount, totalBuyAmount);

        address clone = AssetManagerShared.cloneProtocol(logicStorage, intentProtocol);
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
            sellToken: instr.sellToken,
            expiresAt: uint96(expiresAt_),
            owningProtocol: intentProtocol,
            investedCounted: 0,
            reservedSell: totalSellAmount
        });
        logicStorage.committedIntentSell[instr.sellToken] += totalSellAmount;

        emit IBittyV1IntentProtocol.TwapCreated(twapId, address(this));
    }

    function cancelTwapOrder(AssetManagerStorage storage logicStorage, address intentProtocol, bytes32 twapId)
        external
        onlyInitialized(logicStorage)
    {
        IntentOrderRecord memory record = logicStorage.intentOrderRecords[twapId];
        if (record.sellToken == address(0)) revert InvalidIntentProtocol();

        _executeCancel(logicStorage, intentProtocol, twapId);

        emit IBittyV1IntentProtocol.TwapCancelled(twapId, address(this));
    }

    // ============ Approvals ============

    function _approveNFTIfNeeded(address protocol) private {
        (bool success, bytes memory data) = protocol.staticcall(abi.encodeWithSignature("positionAssetManager()"));
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
}
