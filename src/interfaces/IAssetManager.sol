// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

interface IAssetManager {
    enum AssetType {
        WBTC,
        WETH,
        USDT,
        USDC
    }

    struct RebalanceLimit {
        uint256 minimalWBTCBalance;
        uint256 minimalWETHBalance;
        uint256 minimalStableCoinBalance;
        uint256 minimalDaysRebalance;
        uint256 maxReblancePercentage;
    }

    /**
     * @notice Get the ETH balance of the contract.
     * @return The ETH balance of the contract.
     */
    function getETHBalance() external view returns (uint256);

    /**
     * @notice Convert ETH to WETH.
     * @dev Convert all ETH in the contract to WETH.
     */
    function turnETHToWETH() external;

    /**
     * @notice Get the WETH balance of the contract.
     * @return The WETH balance of the contract.
     */
    function getWETHBalance() external view returns (uint256);

    /**
     * @notice Supply the asset on protocol like Aave to yield.
     * @dev Supply the asset on Aave.
     * @param assetAddress The address of the asset.
     * @param amount The amount of the asset.
     */
    function supply(address assetAddress, uint256 amount) external;

    /**
     * @notice Withdraw the asset from protocol like Aave.
     * @dev Withdraw the asset from protocol like Aave.
     * @param assetAddress The address of the asset.
     * @param amount The amount of the asset.
     */
    function withdraw(address assetAddress, uint256 amount) external;

    /**
     * @notice Rebalance the assets.
     * @dev Rebalance the assets from the from asset type to the to asset type.
     * @param from The type of the from asset.
     * @param to The type of the to asset.
     * @param sellAmount The amount of the sell asset.
     * @param buyAmountMin The minimum amount of the buy asset.
     */
    function rebalance(AssetType from, AssetType to, uint256 sellAmount, uint256 buyAmountMin, bytes calldata data)
        external;

    /**
     * @notice Buy The Limited assets with assets not in AssetType.
     * @dev Buy the limited assets with the sell assets.
     * @param buyAssetType The type of the buy asset.
     * @param sellAssetAddress The address of the sell asset.
     * @param buyAmountMin The minimum amount of the buy asset.
     * @param sellAmount The amount of the sell asset.
     */
    function buy(
        AssetType buyAssetType,
        address sellAssetAddress,
        uint256 buyAmountMin,
        uint256 sellAmount,
        bytes calldata data
    ) external;
}
