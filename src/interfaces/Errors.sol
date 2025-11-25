// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

// Common errors
error AddressZero();
error AmountIsZero();
error LengthMismatch();

// AssetManager errors
error WETHNotSet();
error AssetAlreadySet();
error InvalidAssetType();
error InvalidStableCoinType();
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
error AmountPerWithdrawalIsZero();
error minimalWithdrawDurationLessThan1Day();
error BeneficiarySettingsNotSet();
error BeneficiaryWithdrawalInLimitDays();
error InsufficientStablecoinBalance();
error TransferFailed();
error EventNameIsEmpty();
error EventNameDuplicated();
error EventNameNotFound();
error percentageMoreThan10K();
error EventTriggerError();
error TimestampIsZero();
error TimestampNotFound();
error TimestampDuplicated();
error TimestampIsInTheFuture();

// Grantor errors
error BaseFeeDurationNotMet();
error RevenueDurationNotMet();
error RevenueIsZero();
error RevenuePercentageIsZero();
error RevenueDurationIsZero();

// Factory errors
error InvalidGrantor();
error DeploymentFailed();
error NotWhiteListed();
error Deprecated();

// Subscribe errors
error AlreadySubscribed();
error AlreadyPremium();
error AlreadyBase();
error SubscriptionNone();
error SubscriptionDowngrade();
error SubscriptionUpgrade();
error InsufficientWithdrawableFee();
