// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error SellAmountMismatch();
error BuyAmountNotEnough();
error MinimalBalanceNotMet();
error InvalidLendingProtocol();
error InvalidStakingProtocol();
error InvalidAMMProtocol();
error InvalidIntentProtocol();
error InvalidValidTo();
error InvalidSwapData();
error DisableRebalanceUntilTimestampTooEarly();
error DisableRebalanceUntilTimestampTooLate();
error RebalanceDisabled();
error ETHBalanceNotEnough();
error WETHBalanceNotEnough();

interface IBittyV1AssetManager {
    // ============ Events ============

    event ETHWrapped(uint256 amount);
    event WETHUnwrapped(uint256 amount);
    event MinimalBalanceSet(address indexed asset, uint256 minimalBalance);
    event RebalanceDisabledUntil(uint256 timestamp);
    event LendingProtocolsAdded(address[] protocols);
    event LendingProtocolsRemoved(address[] protocols);
    event StakingProtocolsAdded(address[] protocols);
    event StakingProtocolsRemoved(address[] protocols);
    event AMMProtocolsAdded(address[] protocols);
    event AMMProtocolsRemoved(address[] protocols);
    event IntentProtocolsAdded(address[] protocols);
    event IntentProtocolsRemoved(address[] protocols);

    // ============ Functions ============

    /**
     * @notice Turn the ETH to WETH.
     * @dev Turn the ETH to WETH.
     * @param amount The amount of ETH to turn.
     */
    function ETHToWETH(uint256 amount) external;

    /**
     * @notice Turn the WETH to ETH.
     * @dev Turn the WETH to ETH.
     * @param amount The amount of WETH to turn.
     */
    function WETHToETH(uint256 amount) external;

    /**
     * @notice Get the yield providers.
     * @dev Get the yield providers.
     * @return lendingProtocolAddresses The addresses of the yield providers.
     */
    function getLendingProtocols() external view returns (address[] memory);

    /**
     * @notice Get the staking providers.
     * @dev Get the staking providers.
     * @return stakingProtocolAddresses The addresses of the staking providers.
     */
    function getStakingProtocols() external view returns (address[] memory);

    /**
     * @notice Get the swap providers.
     * @dev Get the swap providers.
     * @return ammProtocolAddresses The addresses of the swap providers.
     */
    function getAMMProtocols() external view returns (address[] memory);

    /// @notice Set the minimum balance that must remain in the vault after any sell of `assetAddress`.
    ///         Use token decimals (e.g. 1e8 = 1 WBTC, 10 ether = 10 WETH). Zero disables the check.
    function setMinimalBalance(address assetAddress, uint256 minimalBalance) external;

    /**
     * @notice Supply the asset to the lending provider.
     * @dev Supply the asset to the lending provider.
     * @param lendingProtocol The address of the lending provider.
     * @param assetAddress The address of the asset.
     * @param amount The amount of the asset.
     */
    function supply(address lendingProtocol, address assetAddress, uint256 amount) external;

    /**
     * @notice Withdraw the asset from the lending provider.
     * @dev Withdraw the asset from the lending provider.
     * @param lendingProtocol The address of the lending provider.
     * @param assetAddress The address of the asset.
     * @param amount The amount of the asset.
     */
    function withdraw(address lendingProtocol, address assetAddress, uint256 amount) external;

    /**
     *
     * @param lendingProtocol The address of the lending provider.
     * @param assetAddress The address of the asset.
     * @return The balance of the asset.
     */
    function getSuppliedBalance(address lendingProtocol, address assetAddress) external view returns (uint256);

    /**
     * @notice Stake the asset to the staking provider.
     * @dev Stake the asset to the staking provider, this only works for ETH mainnet.
     * @param stakingProtocol The address of the staking provider.
     * @param asset The address of the asset.
     * @param amount The amount of the weth.
     */
    function stake(address stakingProtocol, address asset, uint256 amount) external;

    /**
     * @notice Get the staking balance.
     * @dev Get the staking balance.
     * @param stakingProtocol The address of the staking provider.
     * @param asset The address of the asset.
     * @return The staking balance.
     */
    function getStakedBalance(address stakingProtocol, address asset) external view returns (uint256);

    /**
     * @notice Unstake the asset from the staking provider.
     * @dev Unstake the asset from the staking provider, this only works for ETH mainnet.
     * @param stakingProtocol The address of the staking provider.
     * @param asset The address of the asset.
     * @param amount The amount of the asset.
     */
    function unstake(address stakingProtocol, address asset, uint256 amount) external;

    /**
     * @notice Get the unstake request ids.
     * @dev Get the unstake request ids.
     * @param stakingProtocol The address of the staking provider.
     * @return unstakeRequestIds The unstake request ids.
     */
    function getUnstakeRequestIds(address stakingProtocol) external view returns (uint256[] memory);

    /**
     * @notice Claim withdrawn assets from the staking provider.
     * @dev Claim withdrawn assets from the staking provider after unstake requests are finalized.
     * @param stakingProtocol The address of the staking provider.
     * @param requestIds The request ids to claim.
     */
    function claimUnstaked(address stakingProtocol, uint256[] memory requestIds) external;

    /// @notice Exact-input market swap: sell exactly `sellAmount` of `from`, receive ≥ `buyAmountMin` of `to`.
    /// @dev data = abi.encode(from, sellAmount, to, buyAmountMin, path)
    function marketSell(
        address ammProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external;

    /// @notice Exact-output market swap: receive exactly `buyAmount` of `to`, spend ≤ `sellAmountMax` of `from`.
    /// @dev data = abi.encode(from, sellAmountMax, to, buyAmount, reversedPath)
    ///      reversedPath must be encoded in reverse order (to → ... → from) per Uniswap V3 exactOutput.
    function marketBuy(
        address ammProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        bytes memory data
    ) external;

    /**
     * @notice Add liquidity to the AMM provider.
     * @dev Add liquidity to the AMM provider.
     * @param ammProtocol The address of the AMM provider.
     * @param data The data for the add liquidity.
     * @dev Only the asset manager can execute it.
     */
    function addLiquidity(
        address ammProtocol,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external;

    /**
     * @notice Remove liquidity from the AMM provider.
     * @dev Remove liquidity from the AMM provider.
     * @param ammProtocol The address of the AMM provider.
     * @param data The data for the remove liquidity.
     * @dev Only the asset manager can execute it.
     */
    function removeLiquidity(address ammProtocol, bytes memory data) external;

    /**
     * @notice Decrease liquidity from the AMM provider without fully closing the position.
     * @dev Works on both registered and deprecated AMM protocols.
     * @param ammProtocol The address of the AMM provider.
     * @param data The data for the decrease liquidity.
     */
    function decreaseLiquidity(address ammProtocol, bytes memory data) external;

    /**
     * @notice Claim fees from the AMM provider.
     * @dev Claim fees from the AMM provider.
     * @param ammProtocol The address of the AMM provider.
     * @param data The data for the claim fees.
     * @dev Only the asset manager can execute it.
     */
    function claimAMMFees(address ammProtocol, bytes memory data) external;

    /**
     * @notice Get the liquidity of the AMM provider.
     * @dev Get the liquidity of the AMM provider.
     * @param ammProtocol The address of the AMM provider.
     * @param data The data for the get liquidity.
     * @dev Only the asset manager can execute it.
     */
    function getLiquidity(address ammProtocol, bytes memory data) external view returns (uint256);

    /**
     * @notice Disable the rebalance until the timestamp.
     * @dev Disable the rebalance until the timestamp.
     * @param timestamp The timestamp to disable the rebalance until.
     */
    function disableRebalanceUntilTimestamp(uint256 timestamp) external;

    /**
     * @notice Add the lending providers.
     * @param lendingProtocolAddresses The addresses of the lending providers.
     * @dev Add the lending providers.
     */
    function addLendingProtocols(address[] memory lendingProtocolAddresses) external;

    /**
     * @notice Remove the lending providers.
     * @dev Remove the lending providers.
     * @param lendingProtocolAddresses The addresses of the lending providers.
     * @dev Remove the lending providers.
     */
    function removeLendingProtocols(address[] memory lendingProtocolAddresses) external;

    /**
     * @notice Add the staking providers.
     * @dev Add the staking providers.
     * @param stakingProtocolAddresses The addresses of the staking providers.
     * @dev Add the staking providers.
     */
    function addStakingProtocols(address[] memory stakingProtocolAddresses) external;

    /**
     * @notice Remove the staking providers.
     * @dev Remove the staking providers.
     * @param stakingProtocolAddresses The addresses of the staking providers.
     * @dev Remove the staking providers.
     */
    function removeStakingProtocols(address[] memory stakingProtocolAddresses) external;

    /**
     * @notice Add the swap providers.
     * @dev Add the swap providers.
     * @param ammProtocolAddresses The addresses of the swap providers.
     * @dev Add the swap providers.
     */
    function addAMMProtocols(address[] memory ammProtocolAddresses) external;

    /**
     * @notice Remove the swap providers.
     * @dev Remove the swap providers.
     * @param ammProtocolAddresses The addresses of the swap providers.
     * @dev Remove the swap providers.
     */
    function removeAMMProtocols(address[] memory ammProtocolAddresses) external;

    function getIntentProtocols() external view returns (address[] memory);

    function addIntentProtocols(address[] memory intentProtocolAddresses) external;

    function removeIntentProtocols(address[] memory intentProtocolAddresses) external;

    /// @notice Place a sell limit order: sell exactly `sellAmount` of `from`, receive ≥ `buyAmountMin` of `to`.
    /// @return orderId use to cancel via cancelLimitOrder
    function limitSell(
        address intentProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        uint32 validTo
    ) external returns (bytes32 orderId);

    /// @notice Place a buy limit order: receive exactly `buyAmount` of `to`, spend ≤ `sellAmountMax` of `from`.
    /// @return orderId use to cancel via cancelLimitOrder
    function limitBuy(
        address intentProtocol,
        address from,
        address to,
        uint256 buyAmount,
        uint256 sellAmountMax,
        uint32 validTo
    ) external returns (bytes32 orderId);

    function cancelLimitOrder(address intentProtocol, bytes memory data) external;

    function cleanExpiredOrders(address intentProtocol, bytes32[] calldata orderDigests) external;

    /// @notice Create a TWAP sell order: split totalSellAmount into n equal parts executed every partDuration seconds.
    /// @return twapId use to cancel via cancelTwap
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

    /// @notice Cancel an active TWAP and return unfilled sell tokens to the vault.
    function cancelTwap(address intentProtocol, bytes32 twapId) external;

    /// @notice Create a TWAP buy order: spend sellAmountPerPart of `from` every partDuration seconds across n parts,
    ///         receiving at least totalBuyAmount/n of `to` per part.
    /// @param totalBuyAmount minimum total `to` tokens across all n parts (minPartLimit = totalBuyAmount/n)
    /// @param sellAmountPerPart sell tokens per part (totalSellAmount = sellAmountPerPart * n)
    /// @return twapId use to cancel via cancelTwap
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
