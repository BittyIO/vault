// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

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
    }

    struct RebalanceLimit {
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

    function getYieldProviders() external view returns (address[] memory);
    function getSwapProviders() external view returns (address[] memory);

    function setRebalanceRules(RebalanceLimit memory rebalanceLimit) external;
    function setAssetConfig(address assetAddress, AssetConfig memory assetConfig) external;
    function setManageFee(ManageFee memory manageFee) external;

    function supply(address yieldProvider, address assetAddress, uint256 amount) external;
    function withdraw(address yieldProvider, address assetAddress, uint256 amount) external;
    function getBalance(address yieldProvider, address assetAddress) external view returns (uint256);
    function rebalance(
        address swapProvider,
        address from,
        address to,
        uint256 sellAmount,
        uint256 buyAmountMin,
        bytes memory data
    ) external;
    /**
     * @notice Get the trustee base fee.
     * @dev Get the trustee base fee.
     * @param stableCoinAddress The address of the stablecoin to get the money.
     */
    function getBaseFee(address stableCoinAddress) external;

    /**
     * @notice Get the revenue fee.
     * @dev Get the revenue fee.
     * @param stableCoinAddress The address of the stablecoin to get the money.
     */
    function getRevenueFee(address stableCoinAddress) external;

    function addYieldProviders(address[] memory yieldProviderAddresses) external;

    function removeYieldProviders(address[] memory yieldProviderAddresses) external;

    function addSwapProviders(address[] memory swapProviderAddresses) external;

    function removeSwapProviders(address[] memory swapProviderAddresses) external;
}

interface IProvider {
    function initialize(address newOwner) external;
}

interface IYieldProvider is IProvider {
    function supply(address asset, uint256 amount) external payable;
    function withdraw(address asset, uint256 amount) external;
    function getBalance(address asset) external view returns (uint256);
}

interface ISwapProvider is IProvider {
    function swap(bytes memory data) external payable;
}
