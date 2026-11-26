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
error DailyLossAllowanceExceeded();
error PriceFeedMissing(address asset);
error PriceStale(address asset);
error SequencerDown();
error BridgeNotEnabled();
error InvalidBridgeProtocol();
error AssetNotBridgeable();
error BridgeAmountMismatch();
error BridgeToSelf();

/**
 * @dev The adapter call the vault makes, mirrored from protocol-store's IBittyV1BridgeProtocol until
 *      the vault's protocol-contracts pin carries it.
 */
interface IBittyV1BridgeAdapter {
    function bridge(address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        payable
        returns (uint256 received);

    function bridgeTo(
        address token,
        uint256 amount,
        uint256 fee,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes calldata data
    ) external returns (uint256 received);
}

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

    event BridgeEnabledSet(bool enabled, uint64 effectiveAt);
    event Bridged(
        address indexed bridgeProtocol, address indexed asset, uint256 amount, uint256 fee, uint256 received, bytes data
    );
    event BridgedTo(
        address indexed bridgeProtocol,
        address indexed asset,
        uint256 destinationChainId,
        bytes32 indexed recipient,
        uint256 amount,
        uint256 fee,
        uint256 received,
        bytes data
    );
    event WhitelistedRecipientBridged(
        uint256 indexed id,
        address indexed bridgeProtocol,
        address indexed asset,
        uint256 destinationChainId,
        bytes32 recipient,
        uint256 amount,
        uint256 fee,
        uint256 received
    );

    /**
     * @notice Turn the bridge function on or off, both {bridge} and {bridgeTo}. A vault starts with
     *         it on, like market trading: what a bridge to this vault's counterpart loses is bounded
     *         by the daily loss allowance, and what it moves stays under that counterpart, whose own
     *         limits still apply; a bridge to anyone else is a send, bounded by the send allowance.
     * @dev Turning it back on waits out the risk timelock and is refused under a lock; a lock also
     *      drops a pending turn-on. Turning it off applies at once, locked or not.
     */
    function setBridgeEnabled(bool enabled) external;

    /**
     * @return enabled Whether the vault can bridge now.
     * @return enableAt When a pending turn-on takes effect, or 0 if none is waiting.
     */
    function bridgeSettings() external view returns (bool enabled, uint64 enableAt);

    /**
     * @notice Bridge `amount` of `asset` to this vault's counterpart on another chain through
     *         `bridgeProtocol`. Owner only, never an asset manager; not under a lock; and only once
     *         the bridge function is on.
     * @dev The vault does not read the bridge's request itself; the guard-registered adapter does,
     *      and it is the adapter that pins the recipient and bounds what the bridge may keep (see
     *      protocol-store's AcrossBridgeProtocol). The recipient is this vault's counterpart: between
     *      EVM chains its own address, which is the same on every EVM chain; to or from TRON, where
     *      the address differs, the vault its creation owner has there. There is no amount limit, as
     *      for a payout to a default whitelisted address. A bridge only moves money between a vault
     *      and its counterparts, so the set of them is as strong as the weakest.
     *
     *      The counterpart belongs to whoever owns it on that chain. Ownership is per chain: after
     *      this vault is handed to a new key here (a rotation, a sale, the recovery from a stolen
     *      key), the same address elsewhere stays the old key's until it is handed over there too.
     *
     *      `asset` is address(0) for the native coin, which the vault holds as its wrapped gas token
     *      and unwraps for the bridge. The asset (the wrapped gas token, for native) must carry the
     *      guard's bridgeable category, and the protocol the bridge category. Exactly `amount` leaves
     *      the vault, `fee` of it as Bitty's fee, capped by the adapter. What does not arrive on the
     *      other side (the fee and the bridge's cost) is charged to the daily loss allowance, valued
     *      at oracle price, so an asset without a price feed (or a stablecoin) cannot be bridged.
     * @param bridgeProtocol The guard-registered bridge adapter.
     * @param asset The asset to send, address(0) for the native coin.
     * @param amount What leaves the vault, fee included.
     * @param fee Bitty's fee out of `amount`.
     * @param data The adapter's request (Across: abi.encode(AcrossQuote) from Across's quote, followed
     *        by the vault's creation owner to or from TRON).
     */
    function bridge(address bridgeProtocol, address asset, uint256 amount, uint256 fee, bytes calldata data) external;

    /**
     * @notice Bridge `amount` of a stablecoin `asset` to `recipient` on another chain through
     *         `bridgeProtocol`: a send that crosses chains. Owner only, never an asset manager; not
     *         under a lock; and only once the bridge function is on.
     * @dev The whole `amount`, fee included, is metered against the send allowance and its day,
     *      shared with {IBittyV1Vault-send}, exactly as a send of it would be; nothing is charged
     *      to the daily loss allowance. At a send allowance of 0 it is refused, as a send is. The
     *      asset must be a stablecoin even when the send allowance is {NO_LIMIT}, and carry the
     *      guard's bridgeable category; the native coin cannot go this way. The adapter pays
     *      `recipient` and no one else, and still holds the quote to its route (the token that
     *      arrives and the most the bridge may keep). Exactly `amount` leaves the vault. An unfilled
     *      deposit is refunded to this vault.
     *
     *      `recipient` may not be this vault's own address: to this vault's counterpart, {bridge}
     *      is the way, metered only by the daily loss allowance; and the same address on TRON is
     *      not the counterpart, but an address no one holds.
     *
     *      `recipient` is whatever address the owner names there. The vault cannot see the other
     *      chain: an address that is the owner's on this chain need not be on that one (a contract
     *      wallet deployed here only, say), and what is paid to it is gone.
     * @param bridgeProtocol The guard-registered bridge adapter.
     * @param asset The stablecoin to send.
     * @param amount What leaves the vault, fee included.
     * @param fee Bitty's fee out of `amount`.
     * @param destinationChainId The chain `recipient` is on; the adapter refuses a quote for another.
     * @param recipient Who is paid on the destination chain, as 32 bytes: a 20-byte address (EVM,
     *        or TRON without its 0x41 prefix) left-padded, a Solana address in full.
     * @param data The adapter's request (Across: abi.encode(AcrossQuote) from Across's quote).
     */
    function bridgeTo(
        address bridgeProtocol,
        address asset,
        uint256 amount,
        uint256 fee,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes calldata data
    ) external;

    /**
     * @notice Add a whitelisted recipient on one network, or on every EVM chain. Owner only; not
     *         under a lock.
     *
     *         - One network (`chainId` its id, TRON 728126428): `recipient` there, paid only by
     *           {bridgeToWhitelistedRecipient} to that chain. No payout on this chain pays it, and
     *           it is not an escape recipient for {IBittyV1Owner-foreverLock}.
     *         - Every EVM chain (`chainId` = type(uint256).max): the same address on all of them.
     *           Paid here like an ordinary entry (and an escape recipient like one), and by
     *           {bridgeToWhitelistedRecipient} to any chain the guard marks as EVM
     *           (`getUint(keccak256(abi.encode(keccak256("bitty.chain.evm"), chainId))) == 1`) and
     *           a route reaches; never to one it does not mark, like TRON or Solana, which take a
     *           payee of their own.
     *         - This chain (`chainId` 0 or this chain's id): an ordinary entry, as
     *           {IBittyV1Owner-addWhitelistedRecipient} adds.
     * @dev The same protection window, removal rules and lock rules as an entry here, and the same
     *      ids. The vault's own address is refused for another chain or every EVM chain. An address
     *      that is the owner's on one EVM chain need not be on another (a contract wallet deployed
     *      on one only), so every EVM chain is for an address that is the same everywhere, like a
     *      plain key's.
     * @param chainId The network the recipient is on; type(uint256).max for every EVM chain.
     * @param recipient Its address there as 32 bytes: a 20-byte address (EVM, or TRON without its
     *        0x41 prefix) left-padded, a Solana address in full. Only one network's entry may be
     *        wider than 20 bytes ({RecipientNotAnAddress} otherwise).
     * @return id The entry's id.
     */
    function addWhitelistedRecipientOn(uint256 chainId, bytes32 recipient) external returns (uint256 id);

    /**
     * @notice Bridge `amount` of `asset` to whitelisted recipient `id` on `destinationChainId`
     *         through `bridgeProtocol`, with no amount limit, as a payout to a whitelisted recipient
     *         here. Owner only, never an asset manager; allowed under either lock, but only while
     *         the bridge function is on.
     * @dev The entry must reach `destinationChainId` (be on it, or on every EVM chain with that one
     *      marked EVM in the guard; never this chain), the adapter must have a route there, and the
     *      entry be payable now (its window run, not voided by a lock, no
     *      removal landed). Nothing is metered: not the send allowance, not the loss allowance.
     *      Any ERC-20 with the guard's bridgeable category; not the native coin. The entry fixes the
     *      chain and the address, and the adapter is held to both and to its route. Exactly `amount`
     *      leaves the vault; an unfilled deposit is refunded to this vault.
     * @param bridgeProtocol The guard-registered bridge adapter.
     * @param id The whitelisted recipient, on another chain.
     * @param asset The ERC-20 to send.
     * @param amount What leaves the vault, fee included.
     * @param fee Bitty's fee out of `amount`.
     * @param destinationChainId Where the recipient is paid.
     * @param data The adapter's request (Across: abi.encode(AcrossQuote) for that chain).
     */
    function bridgeToWhitelistedRecipient(
        address bridgeProtocol,
        uint256 id,
        address asset,
        uint256 amount,
        uint256 fee,
        uint256 destinationChainId,
        bytes calldata data
    ) external;
}
