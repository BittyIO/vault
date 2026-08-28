// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error NotAssetManager();
error AssetManagerExpired();
error AssetManagerExpiryInPast();
error InvalidDepositableProtocol();
error InvalidWithdrawableProtocol();
error InvalidAMMProtocol();
error InvalidIntentProtocol();
error disableTradeUntilTimestampTooEarly();
error disableTradeUntilTimestampTooLong();
error ProtocolNFT();

/**
 * @title IBittyV1AssetManager
 * @notice Only the vault asset manager's trading/yield functions and their events. Implemented by
 *         {BittyV1VaultDeFiFacet}. Owner-only asset manager config (setAssetManager, protocol
 *         add/remove) lives in {IBittyV1Owner}; asset manager read functions (getBalances,
 *         getLiquidity, protocol getters, …) live in {IBittyV1Vault}.
 */
interface IBittyV1AssetManager {
    event TradingDisabledUntil(uint256 timestamp);

    /**
     * @notice Put an asset into a depositable protocol.
     * @dev One entry for every protocol the vault can deposit into. Supply and stake were the same
     *      call under two names, and the adapters expose it as {IBittyV1Depositable-deposit}, so the
     *      vault does not distinguish the kinds - nor will it have to for kinds added later.
     * @param depositProtocol The protocol to deposit into.
     * @param assetAddress The address of the asset to deposit.
     * @param amount The amount of the asset to deposit.
     */
    function deposit(address depositProtocol, address assetAddress, uint256 amount) external;

    /**
     * @notice Withdraw assets from any protocol the vault holds a position in.
     * @param withdrawProtocol The withdrawable protocol to withdraw assets from.
     * @param assetAddress The address of the asset to withdraw.
     * @param amount The amount of the asset to withdraw.
     */
    function withdraw(address withdrawProtocol, address assetAddress, uint256 amount) external;

    /**
     * @notice Claim one finalized withdrawal.
     * @dev For protocols whose exit is asynchronous - a staking queue, a redemption delay - where
     *      {withdraw} only opens the request and the assets arrive on a later claim.
     * @param withdrawProtocol The protocol to claim from.
     * @param id A pending withdrawal id, as listed by {IBittyV1Vault-getPendingWithdrawalIds}.
     */
    function claimWithdrawal(address withdrawProtocol, uint256 id) external;

    /**
     * @notice Claim several finalized withdrawals.
     * @param withdrawProtocol The protocol to claim from.
     * @param ids The pending withdrawal ids to claim.
     */
    function claimWithdrawals(address withdrawProtocol, uint256[] memory ids) external;

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
     * @notice Disable trading until a timestamp.
     * @param timestamp The timestamp when trading should be disabled.
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
