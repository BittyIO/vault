// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

// common errors
error AddressZero();
error AmountIsZero();
error ArrayLengthMismatch();
error EmptyArray();
error TransferFailed();
error NotInitialized();
error AlreadyInitialized();
error InsufficientBalance();
error ReentrantCall();

// scheduledPayment errors
error ScheduledPaymentNotFound();
error ScheduledPaymentImmutable();
error ScheduledPaymentPaymentCountZero();
error ScheduledPaymentTriggerError();
error ScheduledPaymentNotStartYet();
error ScheduledPaymentStartTimestampInPast();
error ScheduledPaymentInInterval();
error AssetAddressNotContract();
error ProtectionPeriodNotEnded();
error PaymentProtectionTooLong();
error PayMoreThanScheduledPaymentAmount();
error PayScheduledPaymentAmountTriggerEmpty();

// adding assets and protocols errors
error AddingAssetsDisabled();
error AddingProtocolsDisabled();
error OwnerAndPayoutOperatorMustDiffer();

error OwnershipNotTransferable();
// Emergency renounce needs a surviving, trustworthy rescue path — a locked
// immutable scheduled payment (the only entry an attacker with the same key
// cannot forge/remove, and the only one that still pays out permissionlessly in
// an ownerless vault). Without one, renouncing would strand the funds, so the
// call reverts.
error NoRescueTarget();
// After renounce, only locked immutable scheduled payments are payable.
error OnlyImmutablePayableAfterRenounce();
error ImmutableScheduledPaymentLocked();

error NotPayoutOperator();
error PayoutOperatorNotFound();
error PayoutOperatorAlreadyRegistered();

// payment risk-control errors
error PaymentExceedsRiskCap();
error PaymentExceedsPeriodLimit();
error PaymentNotStableCoin();

// whitelisted recipient errors
error WhitelistedRecipientNotFound();
error WhitelistedRecipientAssetNotAllowed();

// payout operator approval errors
error PaymentNotApproved();
error NotPendingApproval();
error NotProposalOwner();
error ScheduledPaymentContentMismatch();
error WhitelistedRecipientContentMismatch();
error PendingSendNotFound();

struct RiskSettings {
    uint64 newPaymentProtection;
    uint64 maxSendValue;
    uint64 maxSendInterval;
    uint64 changeTimelock;
}

struct AutoYield {
    address asset;
    address protocol;
    bool isSupplying;
}

/**
 * @title IBittyV1Vault
 * @notice The vault's shared types, errors, and the no-role (permissionless) + read functions.
 *         Owner-only functions live in {IBittyV1Owner}; asset manager trading/yield functions live in
 *         {IBittyV1AssetManager}.
 *
 * @dev Bitty Vault helps you manage your assets safely across different devices, people or AI agents.
 * There are 3 principles for Bitty Vault design:
 * 1. Provide features like traditional wallets so people can switch to it easily.
 * 2. Provide safer options for users to manage the risk of their assets.
 * 3. Let the owner only ever lower the vault's risk.
 */
interface IBittyV1Vault {
    event ScheduledPaymentsPaid(
        uint256[] ids,
        address[] recipients,
        address[] assetAddresses,
        uint256[] amounts,
        uint256[] remainingPaymentCounts
    );

    struct ScheduledPayment {
        // a more complex scheduledPayment contract can be implemented for advanced users out of this repo
        address recipient;
        // remaining number of payments; set to type(uint256).max for an unlimited scheduled payment that
        // never decrements and so never runs out
        uint256 remainingPaymentCount;
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

    struct WhitelistedRecipient {
        // the payee address; address(0) means the entry does not exist
        address recipient;
        // address(0) = any token may be sent; otherwise only this asset is allowed
        address allowedAsset;
    }

    /**
     * @notice The vault's assets.
     */
    function getAssets() external view returns (address[] memory);

    /**
     * @notice The vault's stablecoins.
     */
    function getStableCoins() external view returns (address[] memory);

    /**
     * @notice The vault's WETH address.
     */
    function wethAddress() external view returns (address);

    /**
     * @notice Check if adding assets is disabled.
     */
    function isAddingAssetsDisabled() external view returns (bool);

    /**
     * @notice Check if adding protocols is disabled.
     */
    function isAddingProtocolsDisabled() external view returns (bool);

    /**
     * @notice The vault's single asset manager (address(0) = none). Only this address may trade.
     */
    function getAssetManager() external view returns (address);

    /**
     * @notice Each asset's default yield route (see {IBittyV1Owner.setAutoYieldings}). For row `i`,
     *         protocols[i] == address(0) means no route is configured and isSupplyings[i] is meaningless.
     */
    function getAutoYieldings(address[] calldata assetAddresses)
        external
        view
        returns (address[] memory protocols, bool[] memory isSupplyings);

    /**
     * @notice The address (besides the vault itself) allowed to trigger {autoYield}. address(0) = only
     *         the vault's own deposit path may trigger it.
     */
    function getAutoYieldTrigger() external view returns (address);

    /**
     * @notice Registered payout operators. Each may propose payments pending owner approval.
     */
    function getPayoutOperators() external view returns (address[] memory);

    /**
     * @notice Check if an address is a payout operator.
     */
    function isPayoutOperator(address account) external view returns (bool);

    /**
     * @notice The vault's currently in-force payment risk controls (all zero = no controls). `maxSendValue`
     *         is in stablecoin whole tokens; a non-zero cap makes the owner one-off send path stablecoin-only.
     *         `changeTimelock` is the delay a loosening of any control must wait. A queued loosening is
     *         reflected here only once its delay has elapsed. `maxSendInterval` is the rolling window
     *         (seconds) over which `maxSendValue` caps the owner's CUMULATIVE one-off sends (0 = per-
     *         transaction cap only). `newPaymentProtection` is the protection window applied to newly added
     *         scheduled payments and whitelisted recipients.
     */
    function getRiskConfig()
        external
        view
        returns (uint64 newPaymentProtection, uint64 maxSendValue, uint64 changeTimelock, uint64 maxSendInterval);

    function getLendingProtocols() external view returns (address[] memory);
    function getStakingProtocols() external view returns (address[] memory);
    function getAMMProtocols() external view returns (address[] memory);
    function getIntentProtocols() external view returns (address[] memory);

    /**
     * @notice Supplied (lending) balances for each (lendingProtocols[i], assetAddresses[i]) pair. Arrays
     *         must be equal length.
     */
    function getSuppliedBalances(address[] calldata lendingProtocols, address[] calldata assetAddresses)
        external
        view
        returns (uint256[] memory balances);

    /**
     * @notice Staked balances for each (stakingProtocols[i], assets[i]) pair. Arrays must be equal length.
     */
    function getStakedBalances(address[] calldata stakingProtocols, address[] calldata assets)
        external
        view
        returns (uint256[] memory balances);

    function getUnstakeRequestIds(address stakingProtocol) external view returns (uint256[] memory);

    /**
     * @notice AMM liquidity for each (ammProtocols[i], data[i]) pair. Arrays must be equal length.
     */
    function getLiquidities(address[] calldata ammProtocols, bytes[] calldata data)
        external
        view
        returns (uint256[] memory liquidities);

    /**
     * @notice Get whitelisted recipient entries by id (recipients[i] == address(0) if not set).
     */
    function getWhitelistedRecipients(uint256[] calldata ids)
        external
        view
        returns (address[] memory recipients, address[] memory allowedAssets);

    /**
     * @notice Sweep the vault's spendable balance of each `assetAddresses[i]` into its configured yield
     *         route. Trigger-gated: callable by the vault itself (on deposit) or the owner-set auto-yield
     *         trigger (see {IBittyV1Owner.setAutoYieldTrigger}). Each entry is a no-op when unconfigured /
     *         nothing spendable.
     */
    function autoYield(address[] calldata assetAddresses) external;

    /**
     * @notice Pay each scheduled payment `ids[i]` its full scheduled amount. Trigger-gated per entry if a
     *         trigger is set on it.
     * @dev May first source each row's funds from yield positions: for row `i`, `stakingAmounts[i]` of the
     *      payment's asset is unstaked from `stakingProtocols[i]` and `lendingAmounts[i]` withdrawn from
     *      `lendingProtocols[i]` into the vault before paying (`address(0)` / `0` = skip that leg). The
     *      staking and lending pairs are independently optional: an empty staking (or lending) pair skips
     *      that leg, but a supplied pair must equal `ids.length`. Pass empty arrays for a plain
     *      vault-balance payout.
     */
    function payScheduled(
        uint256[] calldata ids,
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) external;

    /**
     * @notice Pay a partial amount of a scheduled payment (requires a trigger to be set).
     */
    function payScheduledAmount(uint256 id, uint256 amount) external;

    /**
     * @notice Wrap any native ETH the vault holds into WETH. receive() auto-wraps incoming ETH, but ETH
     *         that arrived before the vault was deployed (e.g. a deposit to the counterfactual address) sits
     *         as raw native ETH the vault's WETH-denominated ETH accounting can't spend; this converts it.
     *         Permissionless — it only moves the vault's own ETH into its own WETH.
     */
    function ETHToWETH() external;
}
