// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error InvalidDepositableProtocol();
error InvalidWithdrawableProtocol();
error InvalidMarketTradeProtocol();
error InvalidIntentProtocol();
error ProtocolNotInstantiated();
error ProtocolLineageMismatch();
error ProtocolNotNewer();
error GrantTooLong();
error AssetManagerExpiryInPast();
error MarketTradeNotSupported();
error MarketTradePriceTooLow();
error MarketTradeExceedsDailyLossAllowance();
error PriceFeedMissing(address asset);
error PriceStale(address asset);
error SequencerDown();

/**
 * @title IBittyV1DeFi
 * @notice The trading/yield surface. Named for the capability, not a caller: it is written once in
 *         {BittyV1VaultDeFiFacet} and reached through the vault's fallback. The facet authorises the
 *         vault's `owner()` and, for what its permissions name, the vault's asset manager
 *         ({IBittyV1Vault-setAssetManager}). Owner-only config (protocol add/remove) lives in {IBittyV1Owner}; the read functions
 *         (getBalances, protocol getters, …) live in {IBittyV1Vault}.
 */
interface IBittyV1DeFi {
    /**
     * @notice Put an asset into a depositable protocol.
     * @dev One entry for every protocol the vault can deposit into. Supply and stake were the same
     *      call under two names, and the adapters expose it as {IBittyV1Yield-deposit}, so the
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
     * @notice Withdraw assets from multiple protocol positions in one call.
     * @dev All arrays must have the same length. Use {withdraw} for a single position.
     * @param withdrawProtocols The protocols to withdraw from.
     * @param assetAddresses The assets to withdraw from each protocol.
     * @param amounts The amounts to withdraw from each protocol.
     */
    function withdraws(
        address[] calldata withdrawProtocols,
        address[] calldata assetAddresses,
        uint256[] calldata amounts
    ) external;

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
     * @notice Approve a token to the intent protocol's spender - whatever the protocol pulls sell tokens
     *         through at settlement (CoW's vault relayer, for one), as its clone names it.
     * @param intentProtocol The intent protocol to approve the spender for.
     * @param token The token to approve.
     */
    function approveIntentSpender(address intentProtocol, address token) external;

    /**
     * @notice Cancel an off-chain intent order. Recorded in the protocol's clone, which then refuses the
     *         order at settlement. Still allowed once the protocol is deprecated.
     * @param intentProtocol The intent protocol the order was placed on.
     * @param orderUid The protocol's own order id (CoW: the order UID).
     */
    function cancelIntentOrder(address intentProtocol, bytes calldata orderUid) external;

    /**
     * @notice Cancel several off-chain intent orders on one protocol in one call.
     * @param intentProtocol The intent protocol the orders were placed on.
     * @param orderUids The protocol's own order ids.
     */
    function cancelIntentOrders(address intentProtocol, bytes[] calldata orderUids) external;
}
