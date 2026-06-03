// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error RebalanceInMinimalTime();
error RebalanceMaxAmount();
error SellAmountMismatch();
error BuyAmountNotEnough();
error MinimalBalanceNotMet();
error InvalidLendingProtocol();
error InvalidStakingProtocol();
error InvalidAMMProtocol();
error InvalidSwapData();
error DisableRebalanceUntilTimestampTooEarly();
error RebalanceDisabled();
error ETHBalanceNotEnough();
error WETHBalanceNotEnough();

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

    /**
     * @notice Set the asset config.
     * @dev Set the asset config.
     * @param assetAddress The address of the asset.
     * @param assetConfig The asset config.
     */
    function setRebalanceConfig(address assetAddress, RebalanceConfig memory assetConfig) external;

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

    /**
     *
     * @param ammProtocol The address of the swap provider.
     * @param from The address of the from asset.
     * @param to The address of the to asset, asset should be in the added registry.
     * @param sellAmount The amount of the from asset to sell.
     * @param buyAmountMin The minimum amount of the to asset to buy.
     * @param data The data for the swap.
     * @dev Rebalance the assets.
     */
    function rebalance(
        address ammProtocol,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external;

    /**
     * @notice Add liquidity to the AMM provider.
     * @dev Add liquidity to the AMM provider.
     * @param ammProtocol The address of the AMM provider.
     * @param data The data for the add liquidity.
     * @dev Only the asset manager can execute it.
     */
    function addLiquidity(address ammProtocol, bytes memory data) external;

    /**
     * @notice Remove liquidity from the AMM provider.
     * @dev Remove liquidity from the AMM provider.
     * @param ammProtocol The address of the AMM provider.
     * @param data The data for the remove liquidity.
     * @dev Only the asset manager can execute it.
     */
    function removeLiquidity(address ammProtocol, bytes memory data) external;

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
}
