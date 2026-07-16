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

error AddingAssetsDisabled();
error AddingProtocolsDisabled();
error OwnerAndAssetManagerMustDiffer();

// sending errors
error SendingDisabled();

// whitelisted recipient errors
error WhitelistedRecipientNotFound();
error WhitelistedRecipientNameAlreadyExists();
error WhitelistedRecipientAssetNotAllowed();

// payment-manager approval errors
error PaymentNotApproved(); // pay attempted before the owner approved a payment-manager proposal
error NotPendingApproval(); // approve called on an entry that is not pending
error NotProposalOwner(); // a payment manager tried to edit/cancel an entry it did not propose
error PendingSendNotFound();

/**
 * @title IBittyV1Vault
 * @notice The vault's shared types, errors, and the no-role (permissionless) + read functions.
 *         Owner-only functions live in {IBittyV1Owner}; asset-manager (ASSET_MANAGER_ROLE) functions
 *         live in {IBittyV1AssetManager}.
 *
 * @dev Bitty Vault helps you manage your assets safely across different devices, people or AI agents.
 * There are 3 principles for Bitty Vault design:
 * 1. Provide features like traditional wallets so people can switch to it easily.
 * 2. Provide safer options for users to manage the risk of their assets.
 * 3. Let the owner only ever lower the vault's risk.
 */
interface IBittyV1Vault {
    // Emitted when a scheduled payment is paid (payScheduled is permissionless / trigger-gated).
    event ScheduledPaymentPaid(
        string indexed name,
        address indexed scheduledPaymentAddress,
        address indexed assetAddress,
        uint256 amount,
        uint8 remainingPaymentCount
    );

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

    struct WhitelistedRecipient {
        // the payee address; address(0) means the entry does not exist
        address recipient;
        // address(0) = any token may be sent; otherwise only this asset is allowed
        address allowedAsset;
    }

    // ============ Reads ============

    /**
     * @notice Human-readable vault name set onchain.
     */
    function name() external view returns (string memory);

    function getAssets() external view returns (address[] memory);
    function getStableCoins() external view returns (address[] memory);
    function isAddingAssetsDisabled() external view returns (bool);
    function isAddingProtocolsDisabled() external view returns (bool);
    function isSendingDisabled() external view returns (bool);

    function getLendingProtocols() external view returns (address[] memory);
    function getStakingProtocols() external view returns (address[] memory);
    function getAMMProtocols() external view returns (address[] memory);
    function getIntentProtocols() external view returns (address[] memory);

    function getSuppliedBalance(address lendingProtocol, address assetAddress) external view returns (uint256);
    function getStakedBalance(address stakingProtocol, address asset) external view returns (uint256);
    function getUnstakeRequestIds(address stakingProtocol) external view returns (uint256[] memory);
    function getLiquidity(address ammProtocol, bytes memory data) external view returns (uint256);

    /**
     * @notice Get a whitelisted recipient entry (recipient == address(0) if not set).
     */
    function getWhitelistedRecipient(string memory name) external view returns (address recipient, address allowedAsset);

    // ============ Permissionless (trigger-gated / keeper) ============

    /**
     * @notice Pay a scheduled payment its full scheduled amount. Trigger-gated if a trigger is set.
     */
    function payScheduled(string memory name) external;

    /**
     * @notice Pay a partial amount of a scheduled payment (requires a trigger to be set).
     */
    function payScheduledAmount(string memory name, uint256 amount) external;

    /**
     * @notice Pay a scheduled payment directly out of a staked position (delivered on-behalf).
     */
    function payScheduledFromStaking(string memory name, address stakingProtocol) external;

    /**
     * @notice Pay a scheduled payment directly out of a supplied (lending) position (on-behalf).
     */
    function payScheduledFromLending(string memory name, address lendingProtocol) external;

    /**
     * @notice Pay a scheduled payment by swapping a vault asset into the payment's asset and
     *         delivering it directly (exact-output). Recipient is the configured payee, never a param.
     * @dev data = abi.encode(fromAsset, sellAmountMax, scheduledPaymentAsset, payAmount, reversedPath).
     */
    function payScheduledFromSwap(
        string memory name,
        address ammProtocol,
        address fromAsset,
        uint256 sellAmountMax,
        bytes memory data
    ) external;

    /**
     * @notice Permissionless cleanup of expired limit orders (does not affect TWAP orders).
     */
    function cleanExpiredLimitOrders(address intentProtocol, bytes32[] calldata orderDigests) external;
}
