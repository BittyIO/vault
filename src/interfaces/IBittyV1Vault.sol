// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

// common errors
error AddressZero();
error AmountIsZero();
error TransferFailed();
error NotInitialized();
error AlreadyInitialized();
error InsufficientBalance();

// scheduledPayment errors
error ScheduledPaymentNotFound();
error ScheduledPaymentNameAlreadyExists();
error ScheduledPaymentImmutable();
error ScheduledPaymentPaymentCountZero();
error ScheduledPaymentTriggerError();
error ScheduledPaymentNotStartYet();
error ScheduledPaymentStartTimestampInPast();
error ScheduledPaymentInInterval();
error ScheduledPaymentIntervalTooShort();
error AssetAddressNotContract();
error NewAddressProtectionOutOfRange();
error NewAddressProtectionCannotDecrease();
error AddressProtectionNotEnded();
error PayMoreThanScheduledPaymentAmount();
error PayScheduledPaymentAmountTriggerEmpty();
error OnlyScheduledPayment();

error AddingAssetsDisabled();
error AddingProtocolsDisabled();
error OwnerAndAssetManagerMustDiffer();

// micro-payment errors
error MicroPaymentAssetNotStableCoin();
error MicroPaymentExceedsMax();
error MicroPaymentInInterval();
error MicroPaymentPayerNotConfigured();
error MicroPaymentLimitOutOfRange();

// whitelisted recipient errors
error WhitelistedRecipientNotFound();
error WhitelistedRecipientNameAlreadyExists();
error WhitelistedRecipientAssetNotAllowed();

/**
 * @title IBittyV1Vault
 * @notice Multi-sigs + Bitty Vault ensure your safe.
 *
 * Vault is not going to fix the safety of private key management, the best practise of private key management is multi-sigs.
 *
 * Vault is going to implement:
 * 1. Familly/Company weekly/monthly spending.
 * 2. Money for kids get in the future.
 * 3. Investment avoiding scams assets by Bitty Guard.
 * 4. Yielding avoid high risk lending/staking protocols by Bitty Guard.
 * 5. Trading avoid scam protocols by Bitty Guard.
 * 6. Stay away from frontend supply chain attacks(which is the biggest security issue in DeFi) when interating with trading/lending/staking protocols.
 */
interface IBittyV1Vault {
    event NameSet(string newName);
    event AssetsAdded(address[] assets);
    event AssetsRemoved(address[] assets);
    event AssetsLocked();
    event ProtocolsLocked();

    event ScheduledPaymentAdded(string indexed name, ScheduledPayment scheduledPayment);
    event ScheduledPaymentUpdated(string indexed name, ScheduledPayment scheduledPayment);
    event ScheduledPaymentRemoved(string indexed name);
    event ScheduledPaymentAddressChanged(
        string indexed name, address indexed oldScheduledPaymentAddress, address indexed newScheduledPaymentAddress
    );
    event NewAddressProtectionSet(uint256 protectionDuration);
    event ScheduledPaymentPaid(
        string indexed name,
        address indexed scheduledPaymentAddress,
        address indexed assetAddress,
        uint256 amount,
        uint8 remainingPaymentCount
    );
    event MicroPaid(address indexed stableCoin, address indexed to, uint256 amount);
    event MicroPaymentLimitSet(address indexed payer, uint256 maxWholeTokens, uint256 interval);
    event WhitelistedRecipientSet(string indexed name, address recipient, address allowedAsset);
    event WhitelistedRecipientRemoved(string indexed name);
    event WhitelistedRecipientPaid(string indexed name, address indexed recipient, address asset, uint256 amount);

    struct ScheduledPayment {
        // a more complex scheduledPayment contract can be implemented for advanced users out of this repo
        address scheduledPaymentAddress;
        // remaining number of payments; set to type(uint8).max (255) for an unlimited scheduled payment that
        // never decrements and so never runs out
        uint8 paymentCount;
        bool isImmutable;
        // if this is true, then the payment will not revert if the balance is insufficient
        bool payWithInsufficientBalance;
        // if this is not address(0), then only this trigger address can trigger the payment
        address trigger;
        address assetAddress;
        uint256 amount;
        uint256 startTimestamp;
        uint256 paymentInterval;
    }

    // An owner-curated payee the owner can pay any amount to on demand.
    struct WhitelistedRecipient {
        // the payee address; address(0) means the entry does not exist
        address recipient;
        // address(0) = any token may be sent; otherwise only this asset is allowed
        address allowedAsset;
    }

    /**
     * @notice set the name of the vault.
     * @param name the name of the vault.
     * @dev Only the owner can set the name of the vault.
     */
    function setName(string memory name) external;

    /**
     * @notice add a scheduledPayment.
     * @param name Unique name; reverts if a scheduledPayment with this name already exists (use updateScheduledPayment or removeScheduledPayment first).
     * @param scheduledPayment scheduledPayment.
     */
    function addScheduledPayment(string memory name, ScheduledPayment calldata scheduledPayment) external;

    /**
     *
     * @param name name of the scheduledPayment.
     * @param scheduledPayment the updated scheduledPayment.
     */
    function updateScheduledPayment(string memory name, ScheduledPayment calldata scheduledPayment) external;

    /**
     * @notice change the scheduledPayment address.
     * @param name name of the scheduledPayment.
     * @param newScheduledPaymentAddress new scheduledPayment address.
     * @dev Only the old scheduledPayment address can execute it.
     */
    function changeScheduledPaymentAddress(string memory name, address newScheduledPaymentAddress) external;

    /**
     * @notice remove a recipient.
     * @param name the name of the recipient.
     */
    function removeScheduledPayment(string memory name) external;

    /**
     * @notice Set the time-lock window applied to every newly added scheduled payment and whitelisted
     * recipient before it can be paid.
     * @param newAddressProtection the new protection window in seconds (0 disables it).
     */
    function setNewAddressProtection(uint256 newAddressProtection) external;

    /**
     * @notice Human-readable name set at deploy time to distinguish vaults with the same owner.
     */
    function name() external view returns (string memory);

    /**
     * @notice Add the assets to the vault.
     * @dev Add the assets to the vault.
     * @param assetAddresses The addresses of the assets.
     */
    function addAssets(address[] memory assetAddresses) external;

    /**
     * @notice Disable the adding assets.
     * @dev Disable the adding assets.
     *
     * After disabling, the assets can not be added, but can be removed.
     * It would be useful when owner try to limit the fund to just buy limited assets like wbtc, weth.
     */
    function disableAddingAssets() external;

    /**
     * @notice Check if the adding assets is disabled.
     * @dev Check if the adding assets is disabled.
     * @return bool True if the adding assets is disabled, false otherwise.
     */
    function isAddingAssetsDisabled() external view returns (bool);

    /**
     * @notice Disable the adding protocols.
     * @dev Disable the adding protocols.
     *
     * After disabling, the protocols can not be added, but can be removed.
     * It would be useful when owner try to limit the fund to just buy limited protocols like aave, curve.
     */
    function disableAddingProtocols() external;

    /**
     * @notice Check if the adding protocols is disabled.
     * @dev Check if the adding protocols is disabled.
     * @return bool True if the adding protocols is disabled, false otherwise.
     */
    function isAddingProtocolsDisabled() external view returns (bool);

    /**
     * @notice Remove the assets from the vault.
     * @dev Remove the assets from the vault.
     * @param assetAddresses The addresses of the assets.
     */
    function removeAssets(address[] memory assetAddresses) external;

    /**
     * @notice Get the assets of the vault.
     * @dev Get the assets of the vault.
     * @return The addresses of the assets.
     */
    function getAssets() external view returns (address[] memory);

    /**
     * @notice Get the stable coins of the vault.
     * @dev Get the stable coins of the vault.
     * @return The addresses of the stable coins.
     */
    function getStableCoins() external view returns (address[] memory);

    /**
     * @notice Pay the scheduledPayment with the full amount.
     * @dev Pay the scheduledPayment.
     * @param name the name of the recipient.
     */
    function payScheduled(string memory name) external;

    /**
     *
     * @param name the name of the recipient.
     * @param amount the amount of the payment.
     * @dev Trigger must be set to execute it, otherwise it may cause some unexpected issues.
     */
    function payScheduledAmount(string memory name, uint256 amount) external;

    /**
     * @notice Pay a scheduledPayment its full scheduled amount directly out of a staked position.
     * @dev The unstaked asset is delivered on-behalf straight to the configured scheduledPayment
     * in a single step. The recipient is taken from the scheduledPayment config, never a parameter
     * — funds can only reach a configured scheduledPayment. Authorization mirrors {payScheduled}.
     * Only synchronous staking protocols are supported.
     * @param name The name of the scheduledPayment.
     * @param stakingProtocol The staking protocol to unstake from.
     */
    function payScheduledFromStaking(string memory name, address stakingProtocol) external;

    /**
     * @notice Pay a scheduledPayment its full scheduled amount directly out of a supplied (lending)
     * position. Same recipient-safety guarantees as {payScheduledFromStaking}.
     * @param name The name of the scheduledPayment.
     * @param lendingProtocol The lending protocol to withdraw from.
     */
    function payScheduledFromLending(string memory name, address lendingProtocol) external;

    /**
     * @notice Pay a scheduledPayment its full scheduled amount by swapping a vault asset into the scheduledPayment's
     * asset and delivering it directly (exact-output; the scheduledPayment gets exactly its scheduled amount).
     * Same recipient-safety guarantees as {payScheduledFromStaking} — the recipient is the configured
     * scheduledPayment, never a parameter.
     * @param name The name of the scheduledPayment.
     * @param ammProtocol The AMM protocol to route the swap through.
     * @param fromAsset The vault asset spent to buy the scheduledPayment's asset.
     * @param sellAmountMax The maximum amount of `fromAsset` to spend.
     * @param data abi.encode(fromAsset, sellAmountMax, scheduledPaymentAsset, payAmount, reversedPath).
     */
    function payScheduledFromSwap(
        string memory name,
        address ammProtocol,
        address fromAsset,
        uint256 sellAmountMax,
        bytes memory data
    ) external;

    /**
     * @notice Send stablecoin from the vault's balance directly to any address (a one-off
     * payment that does not require registering a scheduledPayment).
     * @dev Callable by holders of the dedicated micro-payment role (MICRO_PAYMENT_ROLE) — separate
     * from the owner so the owner is not burdened with routine payouts. Rate-limited PER caller: the
     * asset must be a stablecoin registered on this vault, the caller must have a cap configured by
     * the owner (`setMicroPaymentLimit`), `amount` may not exceed that caller's per-payment cap, and
     * at most one micro-payment may occur per that caller's configured interval on the caller's own
     * clock. Paid from the vault's idle balance.
     * @param stableCoin The stablecoin to send.
     * @param to The recipient address.
     * @param amount The amount to send, in the stablecoin's smallest units.
     */
    function payMicro(address stableCoin, address to, uint256 amount) external;

    /**
     * @notice Set a specific micro-payer's per-payment cap and minimum interval.
     * @dev Owner-only. Changes take effect immediately and apply only to `payer`. `maxWholeTokens`
     * is denominated in whole tokens (e.g. 1000 means 1000 units of the stablecoin, scaled by its
     * decimals at pay time). Setting `maxWholeTokens` to 0 disables that payer. There is no default:
     * a MICRO_PAYMENT_ROLE holder cannot pay until the owner configures a cap for its address. When
     * enabling a payer the cap is bounded by a hard ceiling and the interval by a hard floor (both
     * absolute — even the owner cannot exceed them); an out-of-range value reverts.
     * @param payer The micro-payer address this limit applies to.
     * @param maxWholeTokens The maximum whole-token amount per micro-payment (0 disables the payer).
     * @param interval The minimum number of seconds between this payer's micro-payments.
     */
    function setMicroPaymentLimit(address payer, uint256 maxWholeTokens, uint256 interval) external;

    /**
     * @notice Get a micro-payer's limits and the timestamp of its last micro-payment.
     * @param payer The micro-payer address to query.
     * @return maxWholeTokens The per-payment cap in whole tokens (0 if the payer is not configured).
     * @return interval The minimum seconds between this payer's micro-payments.
     * @return lastTimestamp The timestamp of the payer's last micro-payment (0 if none yet).
     */
    function getMicroPaymentLimit(address payer)
        external
        view
        returns (uint256 maxWholeTokens, uint256 interval, uint256 lastTimestamp);

    /**
     * @notice Add a whitelisted recipient the owner can pay on demand.
     * @dev Owner-only. Reverts if `name` already exists (use updateWhitelistedRecipient) or `recipient`
     * is address(0). `allowedAsset == address(0)` lets the owner pay this recipient in any token,
     * otherwise only `allowedAsset` may be sent.
     * @param name The label for this recipient.
     * @param recipient The payee address.
     * @param allowedAsset The only asset allowed, or address(0) for any asset.
     */
    function addWhitelistedRecipient(string memory name, address recipient, address allowedAsset) external;

    /**
     * @notice Update an existing whitelisted recipient.
     * @dev Owner-only. Reverts if `name` does not exist or `recipient` is address(0).
     * @param name The label of the recipient to update.
     * @param recipient The new payee address.
     * @param allowedAsset The only asset allowed, or address(0) for any asset.
     */
    function updateWhitelistedRecipient(string memory name, address recipient, address allowedAsset) external;

    /**
     * @notice Remove a whitelisted recipient.
     * @dev Owner-only. Reverts if `name` does not exist.
     * @param name The label of the recipient to remove.
     */
    function removeWhitelistedRecipient(string memory name) external;

    /**
     * @notice Pay a whitelisted recipient a discretionary amount from the vault's balance.
     * @dev Owner-only. Reverts if `name` is not a whitelisted recipient or `asset` is not allowed for it. Not
     * rate-limited — recipients are owner-vetted at set time.
     * @param name The whitelisted recipient to pay.
     * @param asset The token to send.
     * @param amount The amount to send, in the asset's smallest units.
     */
    function sendToWhitelistedRecipient(string memory name, address asset, uint256 amount) external;

    /**
     * @notice Get a whitelisted recipient entry.
     * @return recipient The payee (address(0) if not set).
     * @return allowedAsset The allowed asset, or address(0) for any.
     */
    function getWhitelistedRecipient(string memory name) external view returns (address recipient, address allowedAsset);
}

