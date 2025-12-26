// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

interface IVault {
    function turnETHToWETH() external;

    /**
     * @notice Add the assets to the vault.
     * @dev Add the assets to the vault.
     * @param assetAddresses The addresses of the assets.
     */
    function addAssets(address[] memory assetAddresses) external;

    /**
     * @notice Remove the assets from the vault.
     * @dev Remove the assets from the vault.
     * @param assetAddresses The addresses of the assets.
     */
    function removeAssets(address[] memory assetAddresses) external;

    /**
     * @notice Reset the assets of the vault.
     * @dev Reset the assets of the vault.
     * @param assetAddresses The addresses of the assets.
     */
    function resetAssets(address[] memory assetAddresses) external;

    /**
     * @notice Add the stable coins to the vault.
     * @dev Add the stable coins to the vault.
     * @param stableCoinAddresses The addresses of the stable coins.
     */
    function addStableCoins(address[] memory stableCoinAddresses) external;

    /**
     * @notice Remove the stable coins from the vault.
     * @dev Remove the stable coins from the vault.
     * @param stableCoinAddresses The addresses of the stable coins.
     */
    function removeStableCoins(address[] memory stableCoinAddresses) external;

    /**
     * @notice Reset the stable coins of the vault.
     * @dev Reset the stable coins of the vault.
     * @param stableCoinAddresses The addresses of the stable coins.
     */
    function resetStableCoins(address[] memory stableCoinAddresses) external;

    /**
     * @notice Get the assets of the vault.
     * @dev Get the assets of the vault.
     * @return The addresses of the assets.
     */
    function getAssets() external view returns (address[] memory);

    /**
     * @notice Get the stable coins of the vault.
     * @dev Get the stable coins of the vault.
     * @return The addresses of the stable coins.
     */
    function getStableCoins() external view returns (address[] memory);

    /**
     * @notice Withdraw the asset from the trust.
     * @dev Withdraw the asset from the trust.
     * @param assetAddress The address of the asset.
     * @param amount The amount of the asset to withdraw.
     */
    function withdraw(address assetAddress, uint256 amount) external;
}

