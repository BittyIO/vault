// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

interface IAssetManager {
    error WETHNotSet();
    error AssetAlreadySet();
    error InvalidAssetType();
    error RebalanceInMinimalTime();
    error InsufficientBalance();
    error SellAmountMismatch();
    error BuyAmountNotEnough();
    error MinimalWBTCBalanceLimit();
    error MinimalWETHBalanceLimit();
    error MinimalStableCoinBalanceLimit();
    error BaseFeeDurationNotMet();
    error RevenueDurationNotMet();
    error RevenueIsZero();
    error RevenuePercentageIsZero();
    error RevenueDurationIsZero();

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
        uint256 minimalTimestampBetweenRebalances;
        uint256 maxRebalancePercentage;
    }

    struct ManageFee {
        /**
         *
         * @param baseFeeAmount The base fee amount.
         * @dev The base fee amount, if isBaseFeePercentage is true, this is 1 / 10000 as unit.
         */
        uint256 baseFeeAmount;
        /**
         * @dev The base fee duration.
         * @param baseFeeDuration The base fee duration.
         */
        uint256 baseFeeDuration;
        /**
         * @dev Whether the base fee is a percentage.
         * @param isBaseFeePercentage Whether the base fee is a percentage.
         */
        bool isBaseFeePercentage;

        /**
         * @dev The revenue percentage, this is 1 / 10000 as unit.
         * @param revenuePercentage The revenue percentage.
         */
        uint256 revenuePercentage;

        /**
         * @dev The revenue duration.
         * @param revenueDuration The revenue duration.
         */
        uint256 revenueDuration;
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
     * @notice This contract can receive any assets ERC20 that is not in the AssetType enum, Trustee can sell them.
     * @dev Sell the assets not in the AssetType enum to the AssetType
     * @param sellAssetAddress The address of the sell asset.
     * @param sellAmount The amount of the sell asset.
     * @param toAssetType The type of the to asset.
     * @param buyAmountMin The minimum amount of the buy asset.
     * @param data The data for the sell.
     */
    function sellAssetsNotWhiteListed(
        address sellAssetAddress,
        uint256 sellAmount,
        AssetType toAssetType,
        uint256 buyAmountMin,
        bytes calldata data
    ) external;

    /**
     * @notice Get the trustee base fee.
     * @dev Get the trustee base fee.
     */
    function getBaseFee() external;

    /**
     * @notice Get the revenue fee.
     * @dev Get the revenue fee.
     */
    function getRevenueFee() external;
}
