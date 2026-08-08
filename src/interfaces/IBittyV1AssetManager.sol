// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error MinimalBalanceNotMet();
error NotAssetManager();
error InvalidLendingProtocol();
error InvalidStakingProtocol();
error InvalidAMMProtocol();
error InvalidIntentProtocol();
error IntentProtocolMismatch();
error InvalidValidTo();
error DisableRebalanceUntilTimestampTooEarly();
error DisableRebalanceUntilTimestampTooLong();
error RebalanceDisabled();

/**
 * @title IBittyV1AssetManager
 * @notice Only the vault asset manager's trading/yield functions and their events. Implemented by
 *         {BittyV1VaultDeFiFacet}. Owner-only asset manager config (setMinimalBalance, setAssetManager, protocol
 *         add/remove) lives in {IBittyV1Owner}; asset manager read functions (getSuppliedBalance,
 *         getLiquidity, protocol getters, …) live in {IBittyV1Vault}.
 */
interface IBittyV1AssetManager {
    event RebalanceDisabledUntil(uint256 timestamp);

    // ============ Lending ============

    function supply(address lendingProtocol, address assetAddress, uint256 amount) external;

    function withdraw(address lendingProtocol, address assetAddress, uint256 amount) external;

    // ============ Staking ============

    function stake(address stakingProtocol, address asset, uint256 amount) external;

    function unstake(address stakingProtocol, address asset, uint256 amount) external;

    function claimUnstaked(address stakingProtocol, uint256[] memory requestIds) external;

    // ============ AMM liquidity ============

    function addLiquidity(
        address ammProtocol,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external;

    function removeLiquidity(address ammProtocol, bytes memory data) external;

    function decreaseLiquidity(address ammProtocol, bytes memory data) external;

    function claimAMMFees(address ammProtocol, bytes memory data) external;

    // ============ Rebalance ============

    /**
     * @notice Disable rebalancing (asset manager trades) until `timestamp`.
     */
    function disableRebalanceUntilTimestamp(uint256 timestamp) external;

    // ============ Intent (gasless off-chain signing) ============

    /**
     * @notice Pre-approve the intent protocol's settlement relayer for `token` (max), so gasless
     *         off-chain-signed orders can be pulled at settlement. Order placement is entirely off-chain
     *         (sign + post to the orderbook); the vault only custodies tokens, validates via
     *         isValidSignature, and grants this allowance. One approval per sell token.
     */
    function approveIntentRelayer(address intentProtocol, address token) external;

    /**
     * @notice Cancel one or more gasless off-chain orders by invalidating them on the intent protocol's
     *         settlement contract (owner-only). CoW's API can't soft-cancel a vault eip1271 order, so this
     *         on-chain invalidation is how the vault cancels; afterwards no solver can settle them. Batched
     *         so a TWAP's open parts are cancelled in one tx.
     */
    function cancelIntentOrders(address intentProtocol, bytes[] calldata orderUids) external;
}
