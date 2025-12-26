// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

// Common errors
error AddressZero();
error AmountIsZero();
error NotAuthorized();
// AssetManager errors
error RebalanceInMinimalTime();
error InsufficientBalance();
error SellAmountMismatch();
error BuyAmountNotEnough();
error MinimalBalanceNotMet();
error SupplyAmountMismatch();
error WithdrawAmountMismatch();
error InvalidYieldProvider();
error InvalidSwapProvider();
error InvalidSwapData();

// Trust errors
error AlreadyInitialized();
error NotInitialized();
error AutoIrrevocableAfterNoPingNotSet();
error StartDistributionTimestampAlreadySet();
error TimestampIsZero();
error TimestampNotFound();
error InsufficientStablecoinBalance();
error TransferFailed();

// Grantor errors
error BaseFeeDurationNotMet();
error RevenueDurationNotMet();
error RevenueIsZero();
error RevenuePercentageIsZero();
error RevenueDurationIsZero();
error OnlyRevocable();
error OnlyGrantor();
error OnlyTrustee();
error OnlyBeneficiary();
error OnlyAssetManager();

// Factory errors
error NotWhiteListed();
error Deprecated();
error VaultAlreadyDeployed();
error SwapProviderShouldNotBeAllRemoved();

// Subscribe errors
error AlreadySubscribed();
error AlreadyPremium();
error AlreadyBase();
error SubscriptionNone();
error SubscriptionDowngrade();
error SubscriptionUpgrade();
error InsufficientWithdrawableFee();
