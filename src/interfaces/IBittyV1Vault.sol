// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

// common errors
error AddressZero();
error NotRegistered();
error Deprecated();
error AssetNotRegistered();
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

error OwnerAndPayoutOperatorMustDiffer();

error OwnershipNotRenounceable();
error PendingOwnerIsPayoutOperator();
error ImplementationNotRegistered();
error NoRescueTarget();
error OnlyImmutablePayableAfterRenounce();
error ImmutableScheduledPaymentLocked();

error NotPayoutOperator();
error PayoutOperatorNotFound();
error PayoutOperatorAlreadyRegistered();

error NotTrustedForwarder();
error GasBudgetExceeded();
error GasBudgetTooHigh();
error FeeExceedsPerOpCap();
error InvalidRelayedCalldata();
error InvalidAsset();

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
}

/**
 * @title IBittyV1Vault
 * @notice The vault's shared types, errors, and the no-role (permissionless) + read functions.
 *         Owner-only functions live in {IBittyV1Owner}; trading/yield functions live in
 *         {IBittyV1DeFi}.
 *
 * @dev Bitty Vault helps you manage your assets safely across different devices, people or AI agents.
 * There are 3 principles for Bitty Vault design:
 * 1. Provide features like traditional wallets so people can switch to it easily.
 * 2. Provide safer options for users to manage the risk of their assets.
 * 3. Let the owner only ever lower the vault's risk.
 */
interface IBittyV1Vault {
    event ScheduledPaymentPaid(
        uint256 indexed id, address recipient, address asset, uint256 amount, uint256 remainingPaymentCount
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
     * @notice The vault's WETH address.
     */
    function wethAddress() external view returns (address);

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
     * @return expiresAt When the grant lapses; 0 = never.
     * @return pendingManager A manager waiting out the timelock, or zero if nothing is queued.
     * @return pendingAt When that queued grant takes effect; 0 = nothing queued.
     */
    function getAssetManagerSettings()
        external
        view
        returns (address manager, uint64 expiresAt, address pendingManager, uint64 pendingAt);

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
     * @notice Is this account a payout operator?
     * @param account The address of the account to check.
     * @return isPayoutOperator Whether the account is a payout operator.
     */
    function isPayoutOperator(address account) external view returns (bool);

    /**
     * @notice Get the risk config.
     * @return newPaymentProtection The new payment protection.
     * @return maxSendValue The max send value.
     * @return changeTimelock The change timelock.
     * @return maxSendInterval The max send interval.
     */
    function getRiskConfig()
        external
        view
        returns (uint64 newPaymentProtection, uint64 maxSendValue, uint64 changeTimelock, uint64 maxSendInterval);

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
     * @notice Get the AMM liquidity.
     * @param ammProtocols The AMM protocols to get the liquidity for.
     * @param data The data for the liquidity.
     * @return liquidity The liquidity.
     */
    function getLiquidities(address[] calldata ammProtocols, bytes[] calldata data)
        external
        view
        returns (uint256[] memory liquidity);

    /**
     * @notice Auto yield the assets.
     * @param assets The addresses of the assets to auto yield.
     */
    function autoYields(address[] calldata assets) external;

    /**
     * @notice Pay a scheduled payment.
     * @param id The id of the scheduled payment.
     * @param amount The amount to pay.
     */
    function payScheduledAmount(uint256 id, uint256 amount) external;

    /**
     * @notice Wrap any native ETH the vault holds into WETH. receive() auto-wraps incoming ETH, but ETH
     *         that arrived before the vault was deployed (e.g. a deposit to the counterfactual address) sits
     *         as raw native ETH the vault's WETH-denominated ETH accounting can't spend; this converts it.
     *         Permissionless — it only moves the vault's own ETH into its own WETH.
     */
    function ETHToWETH() external;

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
    function gaslessConfig() external view returns (address[] memory assets, uint256 dailyLimit, uint256 maxFeePerOp);

    /**
     * @notice Reimburse the trusted forwarder, in stablecoin, for gas it fronted for this vault.
     * @dev Not subject to the payment-risk controls: this is the vault settling its own gas bill, and
     *      an owner able to block it with maxSendValue = 0 would just be relaying for free. The daily
     *      budget and per-charge ceiling are the controls that apply instead.
     * @param asset The asset to use for the relayer fee.
     * @param amount The amount to reclaim, in `asset` units. The payee is vault config, not an
     *        argument.
     */
    function payRelayerFee(address asset, uint256 amount) external;

    /**
     * @notice Pay a scheduled payment, funding any shortfall from the given positions.
     * @dev If the vault already holds enough of the payment's asset, `withdrawProtocols` is ignored.
     *      Otherwise the deficit — never a caller-supplied amount — is withdrawn from the protocols in
     *      order, each up to its available balance, until the amount is covered. A native (ETH) payment
     *      routes the withdrawn WETH through the vault and unwraps it; an ERC-20 payment is topped up
     *      straight to the recipient. Reverts if the on-hand balance plus every listed protocol still
     *      cannot cover the amount, unless the payment set payWithInsufficientBalance.
     * @param id The id of the scheduled payment.
     * @param withdrawProtocols The withdrawable protocols to draw a shortfall from, in priority order.
     */
    function payScheduled(uint256 id, address[] calldata withdrawProtocols) external;

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
     * @param expiresAt When the grant lapses; 0 = never.
     */
    function setAssetManager(address assetManager, uint64 expiresAt) external;
}
