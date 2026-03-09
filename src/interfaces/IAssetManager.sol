// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

error OnlyAssetManager();
error RebalanceInMinimalTime();
error RebalanceMaxPercentage();
error SellAmountMismatch();
error BuyAmountNotEnough();
error MinimalBalanceNotMet();
error InvalidLendingProvider();
error InvalidStakingProvider();
error InvalidAMMProvider();
error InvalidSwapData();
error DisableRebalanceUntilTimestampTooEarly();
error RebalanceDisabled();

interface IAssetManager {
    struct AssetConfig {
        /**
         * @dev The minimal balance of the asset.
         * @param minimalBalance The minimal balance of the asset.
         */
        uint256 minimalBalance;
        /**
         * @dev The minimal duration between rebalances.
         * @param minimalDurationBetweenRebalances The minimal duration between rebalances.
         */
        uint256 minimalDurationBetweenRebalances;
        /**
         * @dev The max rebalance percentage, 1-10000, 1000 means 10%
         * @param maxRebalancePercentage The max rebalance percentage.
         */
        uint256 maxRebalancePercentage;
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
     * @return swapProviderAddresses The addresses of the swap providers.
     */
    function getAMMProviders() external view returns (address[] memory);

    /**
     * @notice Set the asset config.
     * @dev Set the asset config.
     * @param assetAddress The address of the asset.
     * @param assetConfig The asset config.
     */
    function setAssetConfig(address assetAddress, AssetConfig memory assetConfig) external;

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
    function getLendingBalance(address lendingProvider, address assetAddress) external view returns (uint256);

    /**
     * @notice Stake the asset to the staking provider.
     * @dev Stake the asset to the staking provider, this only works for ETH mainnet.
     * @param stakingProvider The address of the staking provider.
     * @param amount The amount of the weth.
     */
    function stake(address stakingProvider, uint256 amount) external;

    /**
     * @notice Get the staking balance.
     * @dev Get the staking balance.
     * @param stakingProvider The address of the staking provider.
     * @return The staking balance.
     */
    function getStakingBalance(address stakingProvider) external view returns (uint256);

    /**
     * @notice Unstake the asset from the staking provider.
     * @dev Unstake the asset from the staking provider, this only works for ETH mainnet.
     * @param stakingProvider The address of the staking provider.
     * @param amount The amount of the weth.
     */
    function unstake(address stakingProvider, uint256 amount) external;

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
    function claim(address stakingProvider, uint256[] memory requestIds) external;

    /**
     *
     * @param swapProvider The address of the swap provider.
     * @param from The address of the from asset.
     * @param to The address of the to asset, asset should be in the added whitelist.
     * @param sellAmount The amount of the from asset to sell.
     * @param buyAmountMin The minimum amount of the to asset to buy.
     * @param data The data for the swap.
     * @dev Rebalance the assets.
     */
    function rebalance(
        address swapProvider,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external;

    /**
     * @notice Add liquidity to the AMM provider.
     * @dev Add liquidity to the AMM provider.
     * @param ammProvider The address of the AMM provider.
     * @param data The data for the add liquidity.
     * @dev Only the asset manager can execute it.
     */
    function addLiquidity(address ammProvider, bytes memory data) external payable;

    /**
     * @notice Remove liquidity from the AMM provider.
     * @dev Remove liquidity from the AMM provider.
     * @param ammProvider The address of the AMM provider.
     * @param data The data for the remove liquidity.
     * @dev Only the asset manager can execute it.
     */
    function removeLiquidity(address ammProvider, bytes memory data) external payable;

    /**
     * @notice Claim fees from the AMM provider.
     * @dev Claim fees from the AMM provider.
     * @param ammProvider The address of the AMM provider.
     * @param data The data for the claim fees.
     * @dev Only the asset manager can execute it.
     */
    function claimFees(address ammProvider, bytes memory data) external payable;

    /**
     * @notice Get the liquidity of the AMM provider.
     * @dev Get the liquidity of the AMM provider.
     * @param ammProvider The address of the AMM provider.
     * @param data The data for the get liquidity.
     * @dev Only the asset manager can execute it.
     */
    function getLiquidity(address ammProvider, bytes memory data) external view returns (uint256);

    /**
     * @notice Disable the rebalance until the timestamp.
     * @dev Disable the rebalance until the timestamp.
     * @param timestamp The timestamp to disable the rebalance until.
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
     * @param swapProviderAddresses The addresses of the swap providers.
     * @dev Add the swap providers.
     */
    function addAMMProviders(address[] memory swapProviderAddresses) external;

    /**
     * @notice Remove the swap providers.
     * @dev Remove the swap providers.
     * @param swapProviderAddresses The addresses of the swap providers.
     * @dev Remove the swap providers.
     */
    function removeAMMProviders(address[] memory swapProviderAddresses) external;
}
