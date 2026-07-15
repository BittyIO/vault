// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

// common errors
error AddressZero();
error AmountIsZero();
error TransferFailed();
error NotInitialized();
error AlreadyInitialized();
error InsufficientBalance();

// receiver errors
error ReceiverNotFound();
error ReceiverNameAlreadyExists();
error ReceiverImmutable();
error ReceiverPaymentCountZero();
error ReceiverTriggerError();
error ReceiverNotStartYet();
error ReceiverStartTimestampInPast();
error ReceiverInInterval();
error ReceiverIntervalTooShort();
error AssetAddressNotContract();
error NewReceiverProtectionOutOfRange();
error ReceiverProtectionNotEnded();
error PayMoreThanReceiverAmount();
error PayReceiverAmountTriggerEmpty();
error OnlyReceiver();

error AddingAssetsDisabled();
error AddingProtocolsDisabled();
error OwnerAndAssetManagerMustDiffer();

// quick-pay errors
error QuickPayAssetNotStableCoin();
error QuickPayExceedsMax();
error QuickPayInInterval();

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

    event ReceiverAdded(string indexed name, Receiver receiver);
    event ReceiverUpdated(string indexed name, Receiver receiver);
    event ReceiverRemoved(string indexed name);
    event ReceiverAddressChanged(
        string indexed name, address indexed oldReceiverAddress, address indexed newReceiverAddress
    );
    event NewReceiverProtectionSet(uint256 protectionDuration);
    event ReceiverPaid(
        string indexed name,
        address indexed receiverAddress,
        address indexed assetAddress,
        uint256 amount,
        uint8 remainingPaymentCount
    );
    event QuickPaid(address indexed stableCoin, address indexed to, uint256 amount);
    event QuickPayLimitSet(uint256 maxWholeTokens, uint256 interval);

    struct Receiver {
        // a more complex receiver contract can be implemented for advanced users out of this repo
        address receiverAddress;
        // if this is not address(0), then only this trigger address can trigger the payment
        address trigger;
        address assetAddress;
        uint256 amount;
        uint8 paymentCount;
        uint256 startTimestamp;
        uint256 paymentInterval;
        bool isImmutable;
        // if this is true, then the payment will not revert if the balance is insufficient
        bool payWithInsufficientBalance;
    }

    /**
     * @notice set the name of the vault.
     * @param name the name of the vault.
     * @dev Only the owner can set the name of the vault.
     */
    function setName(string memory name) external;

    /**
     * @notice add a receiver.
     * @param name Unique name; reverts if a receiver with this name already exists (use updateReceiver or removeReceiver first).
     * @param receiver receiver.
     */
    function addReceiver(string memory name, Receiver calldata receiver) external;

    /**
     *
     * @param name name of the receiver.
     * @param receiver the updated receiver.
     */
    function updateReceiver(string memory name, Receiver calldata receiver) external;

    /**
     * @notice change the receiver address.
     * @param name name of the receiver.
     * @param newReceiverAddress new receiver address.
     * @dev Only the old receiver address can execute it.
     */
    function changeReceiverAddress(string memory name, address newReceiverAddress) external;

    /**
     * @notice remove a recipient.
     * @param name the name of the recipient.
     */
    function removeReceiver(string memory name) external;

    /**
     * @notice set the new receiver protection.
     * @param newReceiverProtection the new receiver protection.
     */
    function setNewReceiverProtection(uint256 newReceiverProtection) external;

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
     * @notice Pay the receiver with the full amount.
     * @dev Pay the receiver.
     * @param name the name of the recipient.
     */
    function payReceiver(string memory name) external;

    /**
     *
     * @param name the name of the recipient.
     * @param amount the amount of the payment.
     * @dev Trigger must be set to execute it, otherwise it may cause some unexpected issues.
     */
    function payReceiverAmount(string memory name, uint256 amount) external;

    /**
     * @notice Pay a receiver its full scheduled amount directly out of a staked position.
     * @dev The unstaked asset is delivered on-behalf straight to the configured receiver
     * in a single step. The recipient is taken from the receiver config, never a parameter
     * — funds can only reach a configured receiver. Authorization mirrors {payReceiver}.
     * Only synchronous staking protocols are supported.
     * @param name The name of the receiver.
     * @param stakingProtocol The staking protocol to unstake from.
     */
    function payReceiverFromStaking(string memory name, address stakingProtocol) external;

    /**
     * @notice Pay a receiver its full scheduled amount directly out of a supplied (lending)
     * position. Same recipient-safety guarantees as {payReceiverFromStaking}.
     * @param name The name of the receiver.
     * @param lendingProtocol The lending protocol to withdraw from.
     */
    function payReceiverFromLending(string memory name, address lendingProtocol) external;

    /**
     * @notice Pay a receiver its full scheduled amount by swapping a vault asset into the receiver's
     * asset and delivering it directly (exact-output; the receiver gets exactly its scheduled amount).
     * Same recipient-safety guarantees as {payReceiverFromStaking} — the recipient is the configured
     * receiver, never a parameter.
     * @param name The name of the receiver.
     * @param ammProtocol The AMM protocol to route the swap through.
     * @param fromAsset The vault asset spent to buy the receiver's asset.
     * @param sellAmountMax The maximum amount of `fromAsset` to spend.
     * @param data abi.encode(fromAsset, sellAmountMax, receiverAsset, payAmount, reversedPath).
     */
    function payReceiverFromSwap(
        string memory name,
        address ammProtocol,
        address fromAsset,
        uint256 sellAmountMax,
        bytes memory data
    ) external;

    /**
     * @notice Send stablecoin from the vault's balance directly to any address (a one-off
     * payment that does not require registering a receiver).
     * @dev Callable by holders of the dedicated quick-pay role (QUICK_PAY_ROLE) — separate
     * from the owner so the owner is not burdened with routine payouts. Rate-limited: the
     * asset must be a stablecoin registered on this vault, `amount` may not exceed the
     * configured per-payment cap, and at most one quick-pay may occur per configured interval
     * (a single shared clock across all recipients). Paid from the vault's idle balance.
     * @param stableCoin The stablecoin to send.
     * @param to The recipient address.
     * @param amount The amount to send, in the stablecoin's smallest units.
     */
    function quickPay(address stableCoin, address to, uint256 amount) external;

    /**
     * @notice Set the quick-pay per-payment cap and minimum interval.
     * @dev Owner-only. Changes take effect immediately. `maxWholeTokens` is denominated in
     * whole tokens (e.g. 1000 means 1000 units of the stablecoin, scaled by its decimals
     * at pay time). Defaults are 1000 whole tokens and 1 day.
     * @param maxWholeTokens The maximum whole-token amount per quick-pay.
     * @param interval The minimum number of seconds between quick-pays.
     */
    function setQuickPayLimit(uint256 maxWholeTokens, uint256 interval) external;

    /**
     * @notice Get the current quick-pay limits and the last quick-pay timestamp.
     * @return maxWholeTokens The per-payment cap in whole tokens.
     * @return interval The minimum seconds between quick-pays.
     * @return lastTimestamp The timestamp of the last quick-pay (0 if none yet).
     */
    function getQuickPayLimit() external view returns (uint256 maxWholeTokens, uint256 interval, uint256 lastTimestamp);
}

