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
}

interface ILendingProvider {
    function initialize(address newOwner) external;
    function supply(address asset, uint256 amount) external payable;
    function withdraw(address asset, uint256 amount) external;
    function getBalance(address asset) external view returns (uint256);
}

interface ISwapProvider {
    function initialize(address newOwner) external;
    function swap(bytes memory data) external payable;
}
