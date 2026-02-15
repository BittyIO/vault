// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

// Common errors
error AddressZero();
error AmountIsZero();

// Vault errors
error InsufficientBalance();
error InsufficientStablecoinBalance();
error TransferFailed();
error NotInitialized();
error AlreadyInitialized();

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
