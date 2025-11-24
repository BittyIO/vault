// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

/**
 * @title Manage the white listed assets, stable coins, yield providers, swap providers of the BittyVault.
 * @dev BittyVault can manage the white listed assets, stable coins, yield providers, swap providers of the BittyVault, including adding and removing assets.
 *
 * 1. No leverage.
 * 2. Cashflow assets only.
 * 3. Leading yield & swap providers only.
 */

interface IWhiteList {
    /**
     * @notice Add a white listed asset to the BittyVault.
     * @dev Add a white listed asset to the BittyVault.
     * @param assetAddresses The addresses of the assets.
     */
    function addAssets(address[] memory assetAddresses) external;

    /**
     * @notice Deprecate a white listed asset from the BittyVault.
     * @dev Deprecate a white listed asset from the BittyVault.
     *      A deprecated asset can only be sold instead of being bought.
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
     * @notice Add a stable coin to the BittyVault.
     * @dev Add a stable coin to the BittyVault.
     * @param stableCoinAddresses The addresses of the stable coins.
     */
    function addStableCoins(address[] memory stableCoinAddresses) external;

    /**
     * @notice Deprecate a stable coin from the BittyVault.
     * @dev Deprecate a stable coin from the BittyVault.
     *      A deprecated stable coin can only be sold, can not be bought anymore.
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
     * @notice Add a yield provider to the BittyVault.
     * @dev Add a yield provider to the BittyVault.
     * @param yieldProviderAddresses The addresses of the yield providers.
     */
    function addYieldProviders(address[] memory yieldProviderAddresses) external;

    /**
     * @notice Deprecate a yield provider from the BittyVault.
     * @dev Deprecate a yield provider from the BittyVault.
     *      A deprecated yield provider is only used for withdrawals, can not supply to it anymore.
     * @param yieldProviderAddresses The addresses of the yield providers.
     */
    function deprecateYieldProviders(address[] memory yieldProviderAddresses) external;

    /**
     * @notice Check if a yield provider is white listed.
     * @dev Check if a yield provider is white listed.
     * @param yieldProviderAddress The address of the yield provider.
     * @return bool True if the yield provider is white listed, false otherwise.
     */
    function isYieldProviderWhiteListed(address yieldProviderAddress) external view returns (bool);

    /**
     * @notice Check if a yield provider is deprecated.
     * @dev Check if a yield provider is deprecated.
     * @param yieldProviderAddress The address of the yield provider.
     * @return bool True if the yield provider is deprecated, false otherwise.
     */
    function isYieldProviderDeprecated(address yieldProviderAddress) external view returns (bool);

    /**
     * @notice Add a swap provider to the BittyVault.
     * @dev Add a swap provider to the BittyVault.
     * @param swapProviderAddresses The addresses of the swap providers.
     */
    function addSwapProviders(address[] memory swapProviderAddresses) external;

    /**
     * @notice Remove a swap provider from the BittyVault.
     * @dev Remove a swap provider from the BittyVault.
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
