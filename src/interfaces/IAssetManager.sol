// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error OnlyAssetManager();
error RebalanceInMinimalTime();
error RebalanceMaxAmount();
error SellAmountMismatch();
error BuyAmountNotEnough();
error MinimalBalanceNotMet();
error InvalidLendingProvider();
error InvalidStakingProvider();
error InvalidAMMProvider();
error InvalidIntentProvider();
error InvalidSwapData();
error InvalidValidTo();
error DisableRebalanceUntilTimestampTooEarly();
error RebalanceDisabled();

interface IAssetManager {
    /**
     * @notice Asset config for the asset, Asset config can be something like the following:
     * USDC, minimalBalance = 1000,000, minimalDuration = 13 seconds, maxAmount = 0
     * WBTC, minimalBalance = 1, minimalDuration = 13 seconds, maxAmount = 0.1 WBTC
     * WETH, minimalBalance = 10, minimalDuration = 13 seconds, maxAmount = 1 WETH
     *
     * @param minimalBalance The minimal balance of the asset.
     * @param minimalDuration The minimal duration between rebalances.
     * @param maxAmount The max rebalance amount of the asset.
     */
    struct RebalanceConfig {
        /**
         * @dev The minimal balance of the asset.
         * @param minimalBalance The minimal balance of the asset.
         * @dev The minimal balance of the asset should remained after the rebalance, can be 0 to sell all of the asset.
         *      If the minimal balance is not 0, use the receiver to get the remaining asset.
         */
        uint256 minimalBalance;
        /**
         * @dev The minimal duration between rebalances.
         * @param minimalDuration The minimal duration between rebalances.
         * @dev If the minimal duration is 0, means the asset config is null for the asset,
         *      so make sure set it to a non-zero value if you want to use the rebalance config.
         */
        uint256 minimalDuration;
        /**
         * @dev The max rebalance amount of the asset, if it is set to 0, means no limit for rebalance.
         * @param maxAmount The max rebalance amount of the asset.
         */
        uint256 maxAmount;
    }

    /**
     * @notice Get the yield providers.
     * @dev Get the yield providers.
     * @return lendingProviderAddresses The addresses of the yield providers.
     */
    function getLendingProviders() external view returns (address[] memory);

    /**
     * @notice Get the staking providers.
     * @dev Get the staking providers.
     * @return stakingProviderAddresses The addresses of the staking providers.
     */
    function getStakingProviders() external view returns (address[] memory);

    /**
     * @notice Get the swap providers.
     * @dev Get the swap providers.
     * @return ammProviderAddresses The addresses of the swap providers.
     */
    function getAMMProviders() external view returns (address[] memory);

    /**
     * @notice Get the intent providers.
     * @dev Get the intent providers.
     * @return intentProviderAddresses The addresses of the intent providers.
     */
    function getIntentProviders() external view returns (address[] memory);

    /**
     * @notice Set the asset config.
     * @dev Set the asset config.
     * @param assetAddress The address of the asset.
     * @param assetConfig The asset config.
     */
    function setRebalanceConfig(address assetAddress, RebalanceConfig memory assetConfig) external;

    /**
     * @notice Change the asset manager address.
     * @dev Change the asset manager address.
     * @param newAssetManager The address of the new asset manager.
     * @dev Only the current asset manager can execute it.
     */
    function changeAssetManagerAddress(address newAssetManager) external;

    /**
     * @notice Supply the asset to the lending provider.
     * @dev Supply the asset to the lending provider.
     * @param lendingProvider The address of the lending provider.
     * @param assetAddress The address of the asset.
     * @param amount The amount of the asset.
     */
    function supply(address lendingProvider, address assetAddress, uint256 amount) external;

    /**
     * @notice Withdraw the asset from the lending provider.
     * @dev Withdraw the asset from the lending provider.
     * @param lendingProvider The address of the lending provider.
     * @param assetAddress The address of the asset.
     * @param amount The amount of the asset.
     */
    function withdraw(address lendingProvider, address assetAddress, uint256 amount) external;

    /**
     *
     * @param lendingProvider The address of the lending provider.
     * @param assetAddress The address of the asset.
     * @return The balance of the asset.
     */
    function getSuppliedBalance(address lendingProvider, address assetAddress) external view returns (uint256);

    /**
     * @notice Stake the asset to the staking provider.
     * @dev Stake the asset to the staking provider, this only works for ETH mainnet.
     * @param stakingProvider The address of the staking provider.
     * @param asset The address of the asset.
     * @param amount The amount of the weth.
     */
    function stake(address stakingProvider, address asset, uint256 amount) external;

    /**
     * @notice Get the staking balance.
     * @dev Get the staking balance.
     * @param stakingProvider The address of the staking provider.
     * @param asset The address of the asset.
     * @return The staking balance.
     */
    function getStakedBalance(address stakingProvider, address asset) external view returns (uint256);

    /**
     * @notice Unstake the asset from the staking provider.
     * @dev Unstake the asset from the staking provider, this only works for ETH mainnet.
     * @param stakingProvider The address of the staking provider.
     * @param asset The address of the asset.
     * @param amount The amount of the asset.
     */
    function unstake(address stakingProvider, address asset, uint256 amount) external;

    /**
     * @notice Get the unstake request ids.
     * @dev Get the unstake request ids.
     * @param stakingProvider The address of the staking provider.
     * @return unstakeRequestIds The unstake request ids.
     */
    function getUnstakeRequestIds(address stakingProvider) external view returns (uint256[] memory);

    /**
     * @notice Claim withdrawn assets from the staking provider.
     * @dev Claim withdrawn assets from the staking provider after unstake requests are finalized.
     * @param stakingProvider The address of the staking provider.
     * @param requestIds The request ids to claim.
     */
    function claimUnstaked(address stakingProvider, uint256[] memory requestIds) external;

    /**
     *
     * @param ammProvider The address of the swap provider.
     * @param from The address of the from asset.
     * @param to The address of the to asset, asset should be in the added whitelist.
     * @param sellAmount The amount of the from asset to sell.
     * @param buyAmountMin The minimum amount of the to asset to buy.
     * @param data The data for the swap.
     * @dev Rebalance the assets.
     */
    function ammRebalance(
        address ammProvider,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external;

    /**
     * @notice Rebalance assets using an intent-based provider (CoW, UniswapX).
     * @dev Creates an intent order for async settlement. The sell tokens are transferred
     *      to the intent provider immediately; buy tokens arrive when the order settles.
     *      Same ammRebalance constraints apply (maxPercentage, minimalDuration, minimalBalance).
     * @param intentProvider The address of the intent provider.
     * @param from The address of the from asset.
     * @param to The address of the to asset, asset should be in the added whitelist.
     * @param sellAmount The amount of the from asset to sell.
     * @param buyAmountMin The minimum amount of the to asset to buy.
     * @param validTo The expiry timestamp of the order (unix seconds).
     * @param isSellOrder True for a sell order (exact sell), false for a buy order (exact buy).
     */
    function intentRebalance(
        address intentProvider,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        uint32 validTo,
        bool isSellOrder
    ) external;

    /**
     * @notice Add liquidity to the AMM provider.
     * @dev Add liquidity to the AMM provider.
     * @param ammProvider The address of the AMM provider.
     * @param data The data for the add liquidity.
     * @dev Only the asset manager can execute it.
     */
    function addLiquidity(address ammProvider, bytes memory data) external;

    /**
     * @notice Remove liquidity from the AMM provider.
     * @dev Remove liquidity from the AMM provider.
     * @param ammProvider The address of the AMM provider.
     * @param data The data for the remove liquidity.
     * @dev Only the asset manager can execute it.
     */
    function removeLiquidity(address ammProvider, bytes memory data) external;

    /**
     * @notice Claim fees from the AMM provider.
     * @dev Claim fees from the AMM provider.
     * @param ammProvider The address of the AMM provider.
     * @param data The data for the claim fees.
     * @dev Only the asset manager can execute it.
     */
    function claimAMMFees(address ammProvider, bytes memory data) external;

    /**
     * @notice Get the liquidity of the AMM provider.
     * @dev Get the liquidity of the AMM provider.
     * @param ammProvider The address of the AMM provider.
     * @param data The data for the get liquidity.
     * @dev Only the asset manager can execute it.
     */
    function getLiquidity(address ammProvider, bytes memory data) external view returns (uint256);

    /**
     * @notice Disable the ammRebalance until the timestamp.
     * @dev Disable the ammRebalance until the timestamp.
     * @param timestamp The timestamp to disable the ammRebalance until.
     */
    function disableRebalanceUntilTimestamp(uint256 timestamp) external;

    /**
     * @notice Add the lending providers.
     * @param lendingProviderAddresses The addresses of the lending providers.
     * @dev Add the lending providers.
     */
    function addLendingProviders(address[] memory lendingProviderAddresses) external;

    /**
     * @notice Remove the lending providers.
     * @dev Remove the lending providers.
     * @param lendingProviderAddresses The addresses of the lending providers.
     * @dev Remove the lending providers.
     */
    function removeLendingProviders(address[] memory lendingProviderAddresses) external;

    /**
     * @notice Add the staking providers.
     * @dev Add the staking providers.
     * @param stakingProviderAddresses The addresses of the staking providers.
     * @dev Add the staking providers.
     */
    function addStakingProviders(address[] memory stakingProviderAddresses) external;

    /**
     * @notice Remove the staking providers.
     * @dev Remove the staking providers.
     * @param stakingProviderAddresses The addresses of the staking providers.
     * @dev Remove the staking providers.
     */
    function removeStakingProviders(address[] memory stakingProviderAddresses) external;

    /**
     * @notice Add the swap providers.
     * @dev Add the swap providers.
     * @param ammProviderAddresses The addresses of the swap providers.
     * @dev Add the swap providers.
     */
    function addAMMProviders(address[] memory ammProviderAddresses) external;

    /**
     * @notice Remove the swap providers.
     * @dev Remove the swap providers.
     * @param ammProviderAddresses The addresses of the swap providers.
     * @dev Remove the swap providers.
     */
    function removeAMMProviders(address[] memory ammProviderAddresses) external;

    /**
     * @notice Add the intent providers.
     * @dev Add the intent providers.
     * @param intentProviderAddresses The addresses of the intent providers.
     */
    function addIntentProviders(address[] memory intentProviderAddresses) external;

    /**
     * @notice Remove the intent providers.
     * @dev Remove the intent providers.
     * @param intentProviderAddresses The addresses of the intent providers.
     */
    function removeIntentProviders(address[] memory intentProviderAddresses) external;

    /**
     * @notice Cancel a pending intent order previously submitted via intentRebalance.
     * @dev Calls cancelTrade on the cloned intent provider. Provider-specific data encoding:
     *      CoW: abi.encode(bytes32 orderDigest, uint32 validTo).
     *      UniswapX: abi.encode(bytes32 hash), or abi.encode(bytes32(0), address sellToken) if canceling approval-only flow.
     * @param intentProvider The address of the intent provider.
     * @param data Encoded cancellation data.
     */
    function cancelIntentRebalance(address intentProvider, bytes memory data) external;

    /**
     * @notice Revoke sell token approvals on an intent provider clone for multiple tokens.
     * @dev Reverts with ApprovalNotFound if the clone has no approval for any token.
     * @param intentProvider The address of the intent provider.
     * @param tokens The sell tokens whose approvals should be revoked.
     */
    function revokeIntentProviderApprovals(address intentProvider, address[] calldata tokens) external;

    /**
     * @notice Permissionlessly clean up multiple expired intent orders on the provider clone.
     * @dev Reverts with OrderNotExpired if validTo has not passed yet for any order.
     * @param intentProvider The address of the intent provider.
     * @param orderDigests The order digests (CoW) or Permit2 hashes (UniswapX).
     */
    function cleanExpiredIntentOrders(address intentProvider, bytes32[] calldata orderDigests) external;
}
