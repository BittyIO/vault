// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

error SwapProviderShouldNotBeAllRemoved();

/**
 * @title Manage the white listed assets and protocols.
 * @dev Manage the white listed assets and protocols by Turtum.
 */
interface IWhiteList {
    /**
     * @notice Add a white listed asset to the TurtumVault.
     * @dev Add a white listed asset to the TurtumVault.
     * @param assetAddresses The addresses of the assets.
     */
    function addAssets(address[] memory assetAddresses) external;

    /**
     * @notice Remove a white listed asset from the TurtumVault.
     * @dev Remove a white listed asset from the TurtumVault.
     *      A removed asset can only be sold instead of being bought.
     * @param assetAddresses The addresses of the assets.
     */
    function removeAssets(address[] memory assetAddresses) external;

    /**
     * @notice Check if an asset is white listed.
     * @dev Check if an asset is white listed.
     * @param assetAddress The address of the asset.
     * @return bool True if the asset is white listed, false otherwise.
     */
    function isAssetWhiteListed(address assetAddress) external view returns (bool);

    /**
     * @notice Add a stable coin to the TurtumVault.
     * @dev Add a stable coin to the TurtumVault.
     * @param stableCoinAddresses The addresses of the stable coins.
     */
    function addStableCoins(address[] memory stableCoinAddresses) external;

    /**
     * @notice Remove a stable coin from the TurtumVault.
     * @dev Remove a stable coin from the TurtumVault.
     *      A removed stable coin can only be sold, can not be bought anymore.
     * @param stableCoinAddresses The addresses of the stable coins.
     */
    function removeStableCoins(address[] memory stableCoinAddresses) external;

    /**
     * @notice Check if a stable coin is white listed.
     * @dev Check if a stable coin is white listed.
     * @param stableCoinAddress The address of the stable coin.
     * @return bool True if the stable coin is white listed, false otherwise.
     */
    function isStableCoinWhiteListed(address stableCoinAddress) external view returns (bool);

    /**
     * @notice Add a yield provider to the TurtumVault.
     * @dev Add a yield provider to the TurtumVault.
     * @param lendingProviderAddresses The addresses of the yield providers.
     */
    function addLendingProviders(address[] memory lendingProviderAddresses) external;

    /**
     * @notice Deprecate a yield provider from the TurtumVault.
     * @dev Deprecate a yield provider from the TurtumVault.
     *      A deprecated yield provider is only used for withdrawals, can not supply to it anymore.
     * @param lendingProviderAddresses The addresses of the yield providers.
     */
    function deprecateLendingProviders(address[] memory lendingProviderAddresses) external;

    /**
     * @notice Check if a yield provider is white listed.
     * @dev Check if a yield provider is white listed.
     * @param lendingProviderAddress The address of the yield provider.
     * @return bool True if the yield provider is white listed, false otherwise.
     */
    function isLendingProviderWhiteListed(address lendingProviderAddress) external view returns (bool);

    /**
     * @notice Check if a yield provider is deprecated.
     * @dev Check if a yield provider is deprecated.
     * @param lendingProviderAddress The address of the yield provider.
     * @return bool True if the yield provider is deprecated, false otherwise.
     */
    function isLendingProviderDeprecated(address lendingProviderAddress) external view returns (bool);

    /**
     * @notice Add a staking provider to the TurtumVault.
     * @dev Add a staking provider to the TurtumVault.
     * @param stakingProviders the addresses of the staking providers.
     */
    function addStakingProviders(address[] memory stakingProviders) external;

    /**
     * @notice Check if a staking provider is white listed.
     * @dev Check if a staking provider is white listed.
     * @param stakingProvider The address of the staking provider.
     * @return bool True if the staking provider is white listed, false otherwise.
     */
    function isStakingProviderWhiteListed(address stakingProvider) external view returns (bool);

    /**
     * @notice Deprecate a staking provider from the TurtumVault.
     * @dev Deprecate a staking provider from the TurtumVault.
     *      A deprecated staking provider is only used for withdrawals, can not supply to it anymore.
     * @param stakingProviders The addresses of the staking providers.
     */
    function deprecateStakingProviders(address[] memory stakingProviders) external;

    /**
     * @notice Check if a staking provider is deprecated.
     * @dev Check if a staking provider is deprecated.
     * @param stakingProviderAddress The address of the staking provider.
     * @return bool True if the staking provider is deprecated, false otherwise.
     */
    function isStakingProviderDeprecated(address stakingProviderAddress) external view returns (bool);

    /**
     * @notice Add a swap provider to the TurtumVault.
     * @dev Add a swap provider to the TurtumVault.
     * @param swapProviderAddresses The addresses of the swap providers.
     */
    function addSwapProviders(address[] memory swapProviderAddresses) external;

    /**
     * @notice Remove a swap provider from the TurtumVault.
     * @dev Remove a swap provider from the TurtumVault.
     * @param swapProviderAddresses The addresses of the swap providers.
     */
    function removeSwapProviders(address[] memory swapProviderAddresses) external;

    /**
     * @notice Check if a swap provider is white listed.
     * @dev Check if a swap provider is white listed.
     * @param swapProviderAddress The address of the swap provider.
     * @return bool True if the swap provider is white listed, false otherwise.
     */
    function isSwapProviderWhiteListed(address swapProviderAddress) external view returns (bool);
}
