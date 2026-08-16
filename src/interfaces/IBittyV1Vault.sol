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
error ScheduledPaymentIntervalTooShort();
error AssetAddressNotContract();
error ProtectionPeriodNotEnded();
error ScheduledPaymentProtectionTooLong();
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

enum RiskControlLevel {
    Zero,
    Standard,
    High
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
    // Batched: {payScheduled} emits one event carrying every payment it actually paid this call (skipped
    // zero-balance entries are excluded). Single-payment paths emit a one-element array. No indexed fields.
    event ScheduledPaymentsPaid(
        uint256[] ids,
        address[] scheduledPaymentAddresses,
        address[] assetAddresses,
        uint256[] amounts,
        uint8[] remainingPaymentCounts
    );

    struct ScheduledPayment {
        // a more complex scheduledPayment contract can be implemented for advanced users out of this repo
        address scheduledPaymentAddress;
        // remaining number of payments; set to type(uint8).max (255) for an unlimited scheduled payment that
        // never decrements and so never runs out
        uint8 remainingPaymentCount;
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

    // ============ Reads ============

    function getAssets() external view returns (address[] memory);
    function getStableCoins() external view returns (address[] memory);
    function wethAddress() external view returns (address);
    function isAddingAssetsDisabled() external view returns (bool);
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

    function isPayoutOperator(address account) external view returns (bool);

    /**
     * @notice The risk-control preset chosen at activation (None/Standard/Strict). The live controls may
     *         have been tuned since — see {getRiskConfig} — but this records the starting preset so the UI
     *         can show it and offer a reset to its defaults.
     */
    function getRiskControlLevel() external view returns (RiskControlLevel);

    /**
     * @notice The vault's currently in-force payment risk controls (all zero = no controls). Caps are in
     *         stablecoin whole tokens; a non-zero cap makes that payment path stablecoin-only.
     *         `changeTimelock` is the delay a loosening of any control must wait. A queued loosening is
     *         reflected here only once its delay has elapsed. `maxSendInterval` is the rolling window
     *         (seconds) over which `maxSendValue` caps the owner's CUMULATIVE one-off sends (0 = per-
     *         transaction cap only).
     */
    function getRiskConfig()
        external
        view
        returns (
            uint64 scheduledPaymentProtection,
            uint64 whitelistedProtection,
            uint64 maxSendValue,
            uint64 maxScheduledValue,
            uint64 maxWhitelistedValue,
            uint64 changeTimelock,
            uint64 maxSendInterval
        );

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

    // ============ Permissionless (trigger-gated / keeper) ============

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
     */
    function payScheduled(uint256[] calldata ids) external;

    /**
     * @notice Pay a partial amount of a scheduled payment (requires a trigger to be set).
     */
    function payScheduledAmount(uint256 id, uint256 amount) external;

    /**
     * @notice Pay a scheduled payment straight out of a staked position (delivered to the configured
     * payee). Trigger-gated like {payScheduled}.
     */
    function payScheduledFromStaking(uint256 id, address stakingProtocol) external;

    /**
     * @notice Pay a scheduled payment straight out of a supplied (lending) position (delivered to the
     * configured payee). Trigger-gated like {payScheduled}.
     */
    function payScheduledFromLending(uint256 id, address lendingProtocol) external;

    /**
     * @notice Wrap any native ETH the vault holds into WETH. receive() auto-wraps incoming ETH, but ETH
     *         that arrived before the vault was deployed (e.g. a deposit to the counterfactual address) sits
     *         as raw native ETH the vault's WETH-denominated ETH accounting can't spend; this converts it.
     *         Permissionless — it only moves the vault's own ETH into its own WETH.
     */
    function ETHToWETH() external;
}
