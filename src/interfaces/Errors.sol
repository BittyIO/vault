// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

// Common errors
error AddressZero();
error AmountIsZero();

// Vault errors
error InsufficientStablecoinBalance();
error TransferFailed();
error NotInitialized();
error AlreadyInitialized();

// AssetManager errors
error RebalanceInMinimalTime();
error RebalanceMaxPercentage();
error InsufficientBalance();
error SellAmountMismatch();
error BuyAmountNotEnough();
error MinimalBalanceNotMet();
error SupplyAmountMismatch();
error WithdrawAmountMismatch();
error InvalidLendingProvider();
error InvalidStakingProvider();
error InvalidSwapProvider();
error InvalidSwapData();
error StakeAmountMismatch();
error UnstakeAmountMismatch();

// Owner errors
error OnlyOwner();
error OnlyAssetManager();

// Factory errors
error NotWhiteListed();
error Deprecated();
error VaultAlreadyDeployed();

// Subscribe errors
error AlreadySubscribed();
error AlreadyPremium();
error AlreadyBase();
error SubscriptionNone();
error SubscriptionDowngrade();
error SubscriptionUpgrade();
error InsufficientWithdrawableFee();
