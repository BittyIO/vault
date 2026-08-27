// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error NotAssetManager();
error AssetManagerExpired();
error AssetManagerExpiryInPast();
error InvalidLendingProtocol();
error InvalidStakingProtocol();
error InvalidAMMProtocol();
error InvalidIntentProtocol();
error disableTradeUntilTimestampTooEarly();
error disableTradeUntilTimestampTooLong();
error ProtocolNFT();

/**
 * @title IBittyV1AssetManager
 * @notice Only the vault asset manager's trading/yield functions and their events. Implemented by
 *         {BittyV1VaultDeFiFacet}. Owner-only asset manager config (setAssetManager, protocol
 *         add/remove) lives in {IBittyV1Owner}; asset manager read functions (getSuppliedBalance,
 *         getLiquidity, protocol getters, …) live in {IBittyV1Vault}.
 */
interface IBittyV1AssetManager {
    event RebalanceDisabledUntil(uint256 timestamp);

    /**
     * @notice Supply assets to a lending protocol.
     * @param lendingProtocol The lending protocol to supply assets to.
     * @param assetAddress The address of the asset to supply.
     * @param amount The amount of the asset to supply.
     */
    function supply(address lendingProtocol, address assetAddress, uint256 amount) external;

    /**
     * @notice Withdraw assets from a lending protocol.
     * @param lendingProtocol The lending protocol to withdraw assets from.
     * @param assetAddress The address of the asset to withdraw.
     * @param amount The amount of the asset to withdraw.
     */
    function withdraw(address lendingProtocol, address assetAddress, uint256 amount) external;

    /**
     * @notice Stake assets to a staking protocol.
     * @param stakingProtocol The staking protocol to stake assets to.
     * @param asset The asset to stake.
     * @param amount The amount of the asset to stake.
     */
    function stake(address stakingProtocol, address asset, uint256 amount) external;

    /**
     * @notice Unstake assets from a staking protocol.
     * @param stakingProtocol The staking protocol to unstake assets from.
     * @param asset The asset to unstake.
     * @param amount The amount of the asset to unstake.
     */
    function unstake(address stakingProtocol, address asset, uint256 amount) external;

    /**
     * @notice Claim a finalized unstake request.
     * @param stakingProtocol The staking protocol to claim the unstake request from.
     * @param requestId The ID of the unstake request to claim.
     */
    function claimUnstaked(address stakingProtocol, uint256 requestId) external;

    /**
     * @notice Claim unstaked assets from a staking protocol.
     * @param stakingProtocol The staking protocol to claim unstaked assets from.
     * @param requestIds The IDs of the unstaked requests to claim.
     */
    function claimUnstakeds(address stakingProtocol, uint256[] memory requestIds) external;

    /**
     * @notice Add liquidity to an AMM protocol.
     * @param ammProtocol The AMM protocol to add liquidity to.
     * @param token0 The first token to add liquidity from.
     * @param amount0 The amount of the first token to add liquidity from.
     * @param token1 The second token to add liquidity from.
     * @param amount1 The amount of the second token to add liquidity from.
     * @param data The data for the add.
     */
    function addLiquidity(
        address ammProtocol,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external;

    /**
     * @notice Remove liquidity from an AMM protocol.
     * @param ammProtocol The AMM protocol to remove liquidity from.
     * @param data The data for the remove.
     */
    function removeLiquidity(address ammProtocol, bytes memory data) external;

    /**
     * @notice Decrease liquidity from an AMM protocol.
     * @param ammProtocol The AMM protocol to decrease liquidity from.
     * @param data The data for the decrease.
     */
    function decreaseLiquidity(address ammProtocol, bytes memory data) external;

    /**
     * @notice Claim fees from an AMM protocol.
     * @param ammProtocol The AMM protocol to claim fees from.
     * @param data The data for the claim.
     */
    function claimAMMFees(address ammProtocol, bytes memory data) external;

    /**
     * @notice Disable rebalancing until a timestamp.
     * @param timestamp The timestamp when rebalancing should be disabled.
     */
    function disableTradeUntilTimestamp(uint256 timestamp) external;

    /**
     * @notice Approve the intent protocol's settlement relayer for a token.
     * @param intentProtocol The intent protocol to approve the relayer for.
     * @param token The token to approve the relayer for.
     */
    function approveIntentRelayer(address intentProtocol, address token) external;

    /**
     * @notice Cancel a gasless off-chain order.
     * @param intentProtocol The intent protocol to cancel the order from.
     * @param orderUid The UID of the order to cancel.
     */
    function cancelIntentOrder(address intentProtocol, bytes calldata orderUid) external;

    /**
     * @notice Cancel multiple gasless off-chain orders.
     * @param intentProtocol The intent protocol to cancel the orders from.
     * @param orderUids The UIDs of the orders to cancel.
     */
    function cancelIntentOrders(address intentProtocol, bytes[] calldata orderUids) external;
}
