// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

/**
 * @title Manage the fund of the Trust.
 * @dev 
 * 1. Yield by Aave, compound.
 * 2. Trade by Uniswap, with limited slippage.     
 */
interface IFundManager {

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
    }

    /**
     * @notice Set the fund manager.
     * @dev Set the fund manager.
     * @param fundManagerAddress The address of the fund manager.
     */
    function setFundManager(address fundManagerAddress) external;

    /**
     * @notice Set the rebalance rules.
     * @dev Set the rebalance rules.
     * @param rebalanceLimit The rebalance limit.
     */
    function setRebalanceRules(IFundManager.RebalanceLimit memory rebalanceLimit) external;

    /**
     * @notice Supply the asset on Aave.
     * @dev Supply the asset on Aave.
     * @param assetAddress The address of the asset.
     * @param amount The amount of the asset.
     */
    function supplyOnAave(address assetAddress, uint256 amount) external;

    /**
     * @notice Withdraw the asset from Aave.
     * @dev Withdraw the asset from Aave.
     * @param assetAddress The address of the asset.
     * @param amount The amount of the asset.
     */
    function withdrawFromAave(address assetAddress, uint256 amount) external;

    /**
     * @notice Rebalance the assets.
     * @dev Rebalance the assets from the from asset type to the to asset type.
     * @param from The type of the from asset.
     * @param to The type of the to asset.
     * @param sellAmount The amount of the sell asset.
     * @param buyAmount The amount of the buy asset.
     * @param slippage The slippage of the buy.
     */
    function rebalance(
        AssetType from,
        AssetType to,
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 slippage
    ) external;

    /**
     * @notice Buy The Limited assets with assets not in AssetType.
     * @dev Buy the limited assets with the sell assets.
     * @param buyAssetType The type of the buy asset.
     * @param sellAssetAddress The address of the sell asset.
     * @param buyAmount The amount of the buy asset.
     * @param sellAmount The amount of the sell asset.
     * @param slippage The slippage of the buy.
     */
    function buy(
        AssetType buyAssetType,
        address sellAssetAddress, 
        uint256 buyAmount,
        uint256 sellAmount,
        uint256 slippage
    ) external;
    
    
}