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
error ReceiverDurationTimestampNotSet();
error ReceiverTriggerError();
error ReceiverNotStartYet();
error ReceiverInDuration();
error OnlyReceiver();

error ETHBalanceNotEnough();
error WETHBalanceNotEnough();
error AddingAssetsDisabled();

/**
 * @title Turtum Vault
 * @notice Multi-sigs + Turtum Vault ensure your safe.
 *
 * Vault is not going to fix the safety of private key management, the best practise of private key management is multi-sigs.
 *
 * Vault is going to implement:
 * 1. Familly/Company weekly/monthly spending.
 * 2. Money for kids get in the future.
 * 3. Investment avoiding scams assets by Turtum whitelist.
 * 4. Yielding avoid high risk lending/staking protocols by Turtum whitelist.
 * 5. Trading avoid scam protocols by Turtum whitelist.
 * 6. Stay away from frontend supply chain attacks(which is the biggest security issue in DeFi) when interating with trading/lending/staking protocols.
 */
interface IVault {
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
    }

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
     * @notice set the asset manager of this vault.
     * @param assetManager the address of asset manager.
     */
    function setAssetManager(address assetManager) external;

    /**
     * @notice Turn the ETH to WETH.
     * @dev Turn the ETH to WETH.
     * @param amount The amount of ETH to turn.
     */
    function ETHToWETH(uint256 amount) external;

    /**
     * @notice Turn the WETH to ETH.
     * @dev Turn the WETH to ETH.
     * @param amount The amount of WETH to turn.
     */
    function WETHToETH(uint256 amount) external;

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
     * After disabling, the assets can not be added, but can be removed or reset.
     * It would be useful when someone try to limit the asset manager to just buy limited assets like wbtc, weth.
     */
    function disableAddingAssets() external;

    /**
     * @notice Remove the assets from the vault.
     * @dev Remove the assets from the vault.
     * @param assetAddresses The addresses of the assets.
     */
    function removeAssets(address[] memory assetAddresses) external;

    /**
     * @notice Add the stable coins to the vault.
     * @dev Add the stable coins to the vault.
     * @param stableCoinAddresses The addresses of the stable coins.
     */
    function addStableCoins(address[] memory stableCoinAddresses) external;

    /**
     * @notice Remove the stable coins from the vault.
     * @dev Remove the stable coins from the vault.
     * @param stableCoinAddresses The addresses of the stable coins.
     */
    function removeStableCoins(address[] memory stableCoinAddresses) external;

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
     *
     * @param name the name of the recipient.
     * @dev Trigger or anyone can execute it.
     */
    function payReceiver(string memory name) external;
}

