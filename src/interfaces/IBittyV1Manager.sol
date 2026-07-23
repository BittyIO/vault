// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error SellAmountMismatch();
error BuyAmountNotEnough();
error MinimalBalanceNotMet();
error TradeSizeExceeded();
error TradeInInterval();
error TradeMustTouchStableCoin();
error TradeLimitExpired();
error TradeInvestedTotalExceeded();
error StableCoinInvestCapZero();
error NotManager();
error InvalidLendingProtocol();
error InvalidStakingProtocol();
error InvalidAMMProtocol();
error InvalidIntentProtocol();
error IntentProtocolMismatch();
error InvalidValidTo();
error InvalidSwapData();
error DisableRebalanceUntilTimestampTooEarly();
error DisableRebalanceUntilTimestampTooLong();
error RebalanceDisabled();

/**
 * @title IBittyV1Manager
 * @notice Only the vault manager's trading/yield functions and their events. Implemented by
 *         {BittyV1VaultDeFiFacet}. Owner-only manager config (setMinimalBalance, setManager, protocol
 *         add/remove) lives in {IBittyV1Owner}; manager read functions (getSuppliedBalance,
 *         getLiquidity, protocol getters, …) live in {IBittyV1Vault}.
 */
interface IBittyV1Manager {
    event RebalanceDisabledUntil(uint256 timestamp);

    // ============ Lending ============

    function supply(address lendingProtocol, address assetAddress, uint256 amount) external;

    function withdraw(address lendingProtocol, address assetAddress, uint256 amount) external;

    // ============ Staking ============

    function stake(address stakingProtocol, address asset, uint256 amount) external;

    function unstake(address stakingProtocol, address asset, uint256 amount) external;

    function claimUnstaked(address stakingProtocol, uint256[] memory requestIds) external;

    // ============ AMM ============

    /**
     * @notice Exact-input market swap: sell exactly `sellAmount` of `from`, receive ≥ `buyAmountMin` of `to`.
     * @dev data = abi.encode(from, sellAmount, to, buyAmountMin, path)
     */
    function marketSell(
        address ammProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external;

    /**
     * @notice Exact-output market swap: receive exactly `buyAmount` of `to`, spend ≤ `sellAmountMax` of `from`.
     * @dev data = abi.encode(from, sellAmountMax, to, buyAmount, reversedPath)
     */
    function marketBuy(
        address ammProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        bytes memory data
    ) external;

    function addLiquidity(
        address ammProtocol,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external;

    function removeLiquidity(address ammProtocol, bytes memory data) external;

    function decreaseLiquidity(address ammProtocol, bytes memory data) external;

    function claimAMMFees(address ammProtocol, bytes memory data) external;

    // ============ Rebalance ============

    /**
     * @notice Disable rebalancing (asset-manager trades) until `timestamp`.
     */
    function disableRebalanceUntilTimestamp(uint256 timestamp) external;

    // ============ Intent (limit / TWAP) ============

    /**
     * @notice Place a sell limit order: sell exactly `sellAmount` of `from`, receive ≥ `buyAmountMin` of `to`.
     * @return orderId use to cancel via cancelLimitOrder
     */
    function limitSell(
        address intentProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        uint32 validTo
    ) external returns (bytes32 orderId);

    /**
     * @notice Place a buy limit order: receive exactly `buyAmount` of `to`, spend ≤ `sellAmountMax` of `from`.
     * @return orderId use to cancel via cancelLimitOrder
     */
    function limitBuy(
        address intentProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        uint32 validTo
    ) external returns (bytes32 orderId);

    function cancelLimitOrder(address intentProtocol, bytes memory data) external;

    /**
     * @notice Create a TWAP sell order: split totalSellAmount into n equal parts executed every partDuration seconds.
     * @return twapId use to cancel via cancelTwapOrder
     */
    function twapSell(
        address intentProtocol,
        address from,
        address to,
        uint256 totalSellAmount,
        uint256 minPartLimit,
        uint256 n,
        uint256 partDuration,
        uint256 span
    ) external returns (bytes32 twapId);

    /**
     * @notice Cancel an active TWAP and return unfilled sell tokens to the vault.
     */
    function cancelTwapOrder(address intentProtocol, bytes32 twapId) external;

    /**
     * @notice Create a TWAP buy order: spend sellAmountPerPart of `from` every partDuration seconds across n parts,
     *         receiving at least totalBuyAmount/n of `to` per part.
     * @return twapId use to cancel via cancelTwapOrder
     */
    function twapBuy(
        address intentProtocol,
        address from,
        address to,
        uint256 totalBuyAmount,
        uint256 sellAmountPerPart,
        uint256 n,
        uint256 partDuration,
        uint256 span
    ) external returns (bytes32 twapId);
}
