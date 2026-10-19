// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error AddressZero();
error NotRegistered();
error Deprecated();
error AmountIsZero();
error ArrayLengthMismatch();
error EmptyArray();
error TransferFailed();
error NotInitialized();
error AlreadyInitialized();
error InsufficientBalance();
error ReentrantCall();

error ProtectionPeriodNotEnded();
error RiskTimelockTooLong();
error RiskTimelockTooShort();
error RiskAllowanceOutOfRange();

error OwnershipNotRenounceable();
error NoPendingOwnershipTransfer();
error ImplementationNotRegistered();
error VaultNotNewer();

error NotTrustedForwarder();
error GasBudgetExceeded();
error GasBudgetTooHigh();
error FeeExceedsPerOpCap();
error InvalidRelayedCalldata();
error InvalidAsset();

error PaymentExceedsRiskCap();
error PaymentExceedsPeriodLimit();
error PaymentNotStableCoin();

error WhitelistedRecipientNotFound();
error NoEscapeRecipient();

error VaultLocked();

struct AutoYield {
    address asset;
    address protocol;
}

/**
 * @title IBittyV1Vault
 * @dev There are 3 principles for Bitty Vault design:
 * 1. Each operation that make vault risk more, need timelock.
 * 2. Each operation that make vault risk less, take effect immediately.
 * 3. Even the owner private key got compromised, the timelock will make the lost in control.
 */
struct PendingChanges {
    uint8 lockLevel; // 0 unlocked, 1 emergency locked, 2 locked for ever.

    address newOwner;
    uint64 newOwnerReadyAt;

    address newAssetManager;
    uint64 newAssetManagerAt;
    uint32 newAssetManagerPerms;

    uint64 timelock;
    uint64 timelockAt;
    uint64 sendDailyAllowance;
    uint64 sendDailyAllowanceAt;
    uint64 marketTradeDailyLossAllowance;
    uint64 marketTradeDailyLossAllowanceAt;

    uint64 gasBudgetDaily;
    uint64 gasBudgetDailyAt;
    uint64 maxFeePerOp;
    uint64 maxFeePerOpAt;
}

uint8 constant WHITELIST_REMOVED = 0; // gone, or never issued
uint8 constant WHITELIST_PENDING = 1; // still waiting out the timelock it was added under
uint8 constant WHITELIST_PAYABLE = 2; // can be paid now, lock or no lock
uint8 constant WHITELIST_VOIDED = 3; // a lock landed before it matured, so it never will
uint8 constant WHITELIST_REMOVAL_QUEUED = 4; // payable until `removeAt`, then gone

/**
 * One whitelisted recipient as the contract sees it, so a client reads the list - the vault's way
 * out after a key leaks - straight from state instead of rebuilding it from events.
 */
struct WhitelistEntryView {
    uint256 id;
    /**
     * Zero once removed.
     */
    address recipient;
    /**
     * When it became, or becomes, payable; 0 if it was payable from the start.
     */
    uint64 effectiveAt;
    /**
     * When a queued removal lands; 0 if none is waiting.
     */
    uint64 removeAt;
    /**
     * One of the WHITELIST_* constants above, worked out with the same lock rules a payout uses.
     */
    uint8 status;
}

interface IBittyV1Vault {
    /**
     * @notice Returns the vault lock level: 0 unlocked, 1 emergency locked, 2 locked forever.
     */
    function lockLevel() external view returns (uint8);

    /**
     * @notice Returns all changes waiting to take effect.
     */
    function pendingChanges() external view returns (PendingChanges memory changes);

    /**
     * @notice The whitelisted recipients, read from state: ids `fromId` up to `fromId + count`, cut
     *         off at the last id issued. `getWhitelist(1, type(uint256).max)` returns the whole list.
     * @dev Ids are issued in order from 1 and never reused, so a removed entry stays in the range
     *      with {WHITELIST_REMOVED}. Each entry costs a few storage reads, which is why the range can
     *      be narrowed: a list an attacker has flooded can still be read a page at a time.
     * @param fromId The first id to return.
     * @param count How many ids to return at most.
     * @return lastId The highest id ever issued: the end of the list.
     * @return entries One per id in the range, in order.
     */
    function getWhitelist(uint256 fromId, uint256 count)
        external
        view
        returns (uint256 lastId, WhitelistEntryView[] memory entries);

    /**
     * @notice The vault's WETH address.
     */
    function gasWrappedAddress() external view returns (address);

    /**
     * @notice Get the auto yieldings.
     * @param assetAddresses The addresses of the assets to get the auto yieldings for.
     * @return protocols The protocols for the assets.
     */
    function getAutoYieldings(address[] calldata assetAddresses) external view returns (address[] memory protocols);

    /**
     * @notice Get the address, besides the owner, allowed to trigger an auto yield sweep.
     * @return trigger The trigger, or the zero address if only the owner may sweep.
     */
    function autoYieldTrigger() external view returns (address trigger);

    /**
     * @notice The vault's trading delegate, and anything queued behind the change timelock.
     * @return manager The asset manager, or the zero address if the owner alone may trade.
     * @return expiresAt When the grant lapses, or 0 if there is no manager.
     * @return pendingManager A manager waiting out the timelock, or zero if nothing is queued.
     * @return pendingAt When that queued grant takes effect; 0 = nothing queued.
     * @return permissions The effective grant's permission mask, or 0 if no manager is active.
     * @return pendingPermissions The queued grant's permission mask, or 0 if nothing is queued.
     */
    function getAssetManagerSettings()
        external
        view
        returns (
            address manager,
            uint64 expiresAt,
            address pendingManager,
            uint64 pendingAt,
            uint32 permissions,
            uint32 pendingPermissions
        );

    /**
     * @notice Is this asset allowed?
     * @param asset The address of the asset to check.
     * @return isAllowed Whether the asset is allowed.
     */
    function isAssetAllowed(address asset) external view returns (bool);

    /**
     * @notice Is this protocol enabled on the vault?
     * @param protocol The address of the protocol to check.
     * @return isAllowed Whether the protocol is allowed.
     */
    function isProtocolAllowed(address protocol) external view returns (bool);

    /**
     * @notice Get the vault's three risk numbers.
     * @return timelock The one wait in front of everything deferred.
     * @return sendDailyAllowance What may leave per day through regular sends, in whole USD; never 0.
     * @return marketTradeDailyLossAllowance What market trades may lose against oracle value per day,
     *         in whole USD; never 0.
     */
    function riskSettings()
        external
        view
        returns (uint64 timelock, uint64 sendDailyAllowance, uint64 marketTradeDailyLossAllowance);

    /**
     * @notice Get what the vault holds in withdrawable protocols.
     * @dev One getter for every protocol the vault can exit, whatever it does with the asset while
     *      it holds it - lending, staking, or anything later that speaks the same interface.
     * @param withdrawProtocols The protocols to get the balances for, one per asset.
     * @param assetAddresses The addresses of the assets to get the balances for.
     * @return balances The balances.
     */
    function getBalances(address[] calldata withdrawProtocols, address[] calldata assetAddresses)
        external
        view
        returns (uint256[] memory balances);

    /**
     * @notice Get the withdrawals awaiting a claim.
     * @dev Empty for protocols that settle {IBittyV1DeFi-withdraw} in the same call.
     * @param withdrawProtocol The protocol to get the pending withdrawal ids for.
     * @return ids The pending withdrawal ids.
     */
    function getPendingWithdrawalIds(address withdrawProtocol) external view returns (uint256[] memory ids);

    /**
     * @notice Auto yield the assets.
     * @param assets The addresses of the assets to auto yield.
     */
    function autoYields(address[] calldata assets) external;

    /**
     * @notice Wrap any native ETH the vault holds into WETH. receive() auto-wraps incoming ETH, but ETH
     *         that arrived before the vault was deployed (e.g. a deposit to the counterfactual address) sits
     *         as raw native ETH the vault's WETH-denominated ETH accounting can't spend; this converts it.
     *         Permissionless — it only moves the vault's own ETH into its own WETH.
     */
    function wrapNative() external;

    /**
     * @notice The trusted ERC-2771 forwarder for this vault (address(0) = relaying disabled).
     * @dev Written once at initialize with no setter, so it can never be repointed by an owner or a
     *      compromised relayer.
     */
    function trustedForwarder() external view returns (address);

    /**
     * @notice What the forwarder may still reclaim from this vault today, as an 18-decimal
     *         whole-stable-coin-token value. Resets at 00:00 UTC.
     * @dev Read before relaying: exceeding the ceiling reverts the whole relayed call, so the caller
     *      should fall back to paying its own gas rather than submit and lose it.
     */
    function gasBudgetRemaining() external view returns (uint256);

    /**
     * @notice The terms on which this vault will pay for relayed gas.
     * @dev One call rather than three, since no caller wants a subset. Deliberately does NOT repeat
     *      {gasBudgetRemaining} — that is live state with its own getter, read on-chain by the
     *      forwarder — nor an `enabled` flag, which `dailyLimit` already carries.
     * @return assets The assets that may pay for relayed gas. Activation seeds this with the
     *         guard's stable coins; EMPTY means NOTHING may pay, so relaying cannot be charged and
     *         no relayed call will go through.
     * @return dailyLimit Per-UTC-day ceiling in whole tokens, as in force. ZERO means relaying is
     *         off: when it is on this is either the owner's figure or DAILY_MAX_GAS_BUDGET, never 0.
     * @return maxFeePerOp Ceiling on a single charge, in whole tokens. Never zero.
     */
    function stableCoinAsGasConfig()
        external
        view
        returns (address[] memory assets, uint256 dailyLimit, uint256 maxFeePerOp);

    /**
     * @notice Reimburse the trusted forwarder, in stablecoin, for gas it fronted for this vault.
     * @dev Callable by the forwarder and ONLY while it is settling a fee for this vault — it must be
     *      inside its own charge window (see {IBittyV1Forwarder}). Being the forwarder is not enough:
     *      every relayed call has the forwarder as `msg.sender`, so that test alone let a relayed
     *      `multicall([payRelayerFee])` signed by any key charge the budget.
     *
     *      Not subject to the payment-risk controls: this is the vault settling its own gas bill, and
     *      an owner able to block it with sendDailyAllowance = 0 would just be relaying for free. The daily
     *      budget and per-charge ceiling are the controls that apply instead.
     * @param asset The asset to use for the relayer fee.
     * @param amount The amount to reclaim, in `asset` units. The payee is vault config, not an
     *        argument.
     */
    function payRelayerFee(address asset, uint256 amount) external;

    /**
     * @notice Auto yield the assets.
     * @param asset The address of the asset to auto yield.
     */
    function autoYield(address asset) external;

    /**
     * @notice Name the address, besides the owner, that may trigger an auto yield sweep.
     * @param trigger The trigger to name. The zero address clears it, leaving the owner alone.
     */
    function setAutoYieldTrigger(address trigger) external;

    /**
     * @notice Name the address, besides the owner, that may trade this vault. Zero revokes.
     * @dev Main vault only; refused on a sub vault. The manager may deposit, withdraw, run LP positions
     *      and sign intent orders, but cannot change which assets or protocols are reachable, cannot
     *      re-route auto-yield, and cannot pay anyone — so daily DeFi work no longer needs the key that
     *      can move money out. Appointing or extending waits out the vault's change timelock; revoking
     *      and shortening apply at once.
     * @param assetManager The trading delegate, or zero to revoke.
     * @param expiresAt When the grant lapses: in the future and within {MAX_GRANT_DURATION}, since every
     *        grant expires. Ignored on a revoke.
     * @param permissions What the grant covers, as the bit set in {Constants}. There is no
     *        "everything" and no default. Unwinding needs no bit: any live manager may withdraw,
     *        claim and cancel orders, since all of it lands back in the vault. So zero appoints a key
     *        that can only unwind.
     */
    function setAssetManager(address assetManager, uint64 expiresAt, uint32 permissions) external;

    /**
     * @notice Emergency lock the vault.
     */
    function emergencyLock() external;

    /**
     * @notice Unlock the vault.
     */
    function unlock() external;

    /**
     * @notice Forever lock the vault.
     * @dev Once engaged nothing can be added, so the only way money ever leaves again is a whitelisted
     *      recipient the owner already had. The owner names one, and the lock refuses with
     *      {NoEscapeRecipient} unless it can be paid right now: it exists, its window has run, no lock
     *      voided it and no removal of it has landed. The vault's own address is refused too, since
     *      paying it moves nothing. A removal still waiting is voided by the lock.
     * @param escapeRecipientId A whitelisted recipient the vault can pay out to after the lock.
     */
    function foreverLock(uint256 escapeRecipientId) external;

    /**
     * @notice Cancel the ownership transfer.
     */
    function cancelOwnershipTransfer() external;
}
