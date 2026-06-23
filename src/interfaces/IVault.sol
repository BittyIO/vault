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
error ReceiverInDuration();
error ReceiverDurationTooShort();
error AssetAddressNotContract();
error NewReceiverProtectionOutOfRange();
error ReceiverProtectionNotEnded();
error PayMoreThanReceiverAmount();
error PayReceiverAmountTriggerEmpty();
error OnlyReceiver();

error AddingAssetsDisabled();
error AddingProtocolsDisabled();
error OwnerAndAssetManagerMustDiffer();

/**
 * @title Bitty Vault
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
interface IVault {
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

    struct Receiver {
        // a more complex receiver contract can be implemented for advanced users out of this repo
        address receiverAddress;
        // if this is not address(0), then only this trigger address can trigger the payment
        address trigger;
        address assetAddress;
        uint256 amount;
        uint8 paymentCount;
        uint256 startTimestamp;
        uint256 durationTimestamp;
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
}

