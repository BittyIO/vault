// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {
    AlreadyInitialized,
    AddressZero,
    AmountIsZero,
    NotInitialized,
    InsufficientBalance
} from "../interfaces/IVault.sol";
import {IWhiteList, NotWhiteListed} from "whitelist-contracts/src/interfaces/IWhiteList.sol";
import {ISubscription} from "subscription-contracts/src/interfaces/ISubscription.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultStorage} from "./Storages.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {
    IVault,
    ReceiverNotFound,
    ReceiverNameAlreadyExists,
    ReceiverImmutable,
    ReceiverPaymentCountZero,
    ReceiverTriggerError,
    ReceiverNotStartYet,
    ReceiverInDuration,
    ETHBalanceNotEnough,
    WETHBalanceNotEnough,
    AddingAssetsDisabled,
    ReceiverDurationTooShort
} from "../interfaces/IVault.sol";

library VaultLogic {
    /**
     * The vault will be drained by one attack in a very short time if no this protection.
     * @dev this is a protection for the vault.
     */
    uint256 constant RECEIVER_MINIMAL_DURATION = 1 days;

    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    modifier onlyInitialized(VaultStorage storage vaultStorage) {
        _onlyInitialized(vaultStorage);
        _;
    }

    function _onlyInitialized(VaultStorage storage vaultStorage) private view {
        if (!vaultStorage.isInitialized) {
            revert NotInitialized();
        }
    }

    modifier onlyNotInitialized(VaultStorage storage vaultStorage) {
        _onlyNotInitialized(vaultStorage);
        _;
    }

    function _onlyNotInitialized(VaultStorage storage vaultStorage) private view {
        if (vaultStorage.isInitialized) {
            revert AlreadyInitialized();
        }
    }

    function initialize(
        VaultStorage storage vaultStorage,
        address weth,
        address whiteListAddress,
        address subscriptionAddress
    ) external onlyNotInitialized(vaultStorage) {
        vaultStorage.weth = weth;
        vaultStorage.whiteList = IWhiteList(whiteListAddress);
        vaultStorage.subscription = ISubscription(subscriptionAddress);
        vaultStorage.isInitialized = true;
    }

    function addReceiver(VaultStorage storage vaultStorage, string memory name, IVault.Receiver memory receiver)
        external
        onlyInitialized(vaultStorage)
    {
        if (vaultStorage.receivers[name].amount != 0) {
            revert ReceiverNameAlreadyExists();
        }
        _checkReceiver(receiver);
        vaultStorage.receivers[name] = receiver;
    }

    function getReceiverAddress(VaultStorage storage vaultStorage, string memory name) external view returns (address) {
        return vaultStorage.receivers[name].receiverAddress;
    }

    function changeReceiverAddress(VaultStorage storage vaultStorage, string memory name, address newReceiverAddress)
        external
        onlyInitialized(vaultStorage)
    {
        IVault.Receiver storage receiver = vaultStorage.receivers[name];
        if (receiver.isImmutable) {
            revert ReceiverImmutable();
        }
        if (newReceiverAddress == address(0)) {
            revert AddressZero();
        }
        receiver.receiverAddress = newReceiverAddress;
    }

    function updateReceiver(VaultStorage storage vaultStorage, string memory name, IVault.Receiver memory receiver)
        external
        onlyInitialized(vaultStorage)
    {
        IVault.Receiver memory existing = vaultStorage.receivers[name];
        if (existing.receiverAddress == address(0)) {
            revert ReceiverNotFound();
        }
        if (existing.isImmutable) {
            revert ReceiverImmutable();
        }
        _checkReceiver(receiver);
        vaultStorage.receivers[name] = receiver;
    }

    function _checkReceiver(IVault.Receiver memory receiver) internal pure {
        if (receiver.receiverAddress == address(0)) {
            revert AddressZero();
        }
        if (receiver.amount == 0) {
            revert AmountIsZero();
        }
        if (receiver.paymentCount == 0) {
            revert ReceiverPaymentCountZero();
        }
        if (receiver.paymentCount > 1 && receiver.durationTimestamp < RECEIVER_MINIMAL_DURATION) {
            revert ReceiverDurationTooShort();
        }
    }

    function removeReceiver(VaultStorage storage vaultStorage, string memory name)
        external
        onlyInitialized(vaultStorage)
    {
        delete vaultStorage.receivers[name];
    }

    function ETHToWETH(VaultStorage storage vaultStorage, uint256 amount) external onlyInitialized(vaultStorage) {
        uint256 ethBalance = address(this).balance;
        if (ethBalance < amount) {
            revert ETHBalanceNotEnough();
        }
        WETH(payable(vaultStorage.weth)).deposit{value: amount}();
    }

    function WETHToETH(VaultStorage storage vaultStorage, uint256 amount) external onlyInitialized(vaultStorage) {
        uint256 wethBalance = IERC20(vaultStorage.weth).balanceOf(address(this));
        if (wethBalance < amount) {
            revert WETHBalanceNotEnough();
        }
        WETH(payable(vaultStorage.weth)).withdraw(amount);
    }

    function payReceiver(VaultStorage storage vaultStorage, string memory name) external {
        IVault.Receiver storage receiver = vaultStorage.receivers[name];
        if (receiver.amount == 0) {
            revert ReceiverNotFound();
        }
        if (receiver.paymentCount == 0) {
            revert ReceiverPaymentCountZero();
        }
        if (receiver.trigger != address(0) && msg.sender != receiver.trigger) {
            revert ReceiverTriggerError();
        }
        if (receiver.startTimestamp > block.timestamp) {
            revert ReceiverNotStartYet();
        }
        if (
            receiver.durationTimestamp != 0 && vaultStorage.lastReceiveTimestamps[name] > 0
                && block.timestamp - vaultStorage.lastReceiveTimestamps[name] < receiver.durationTimestamp
        ) {
            revert ReceiverInDuration();
        }
        vaultStorage.lastReceiveTimestamps[name] = block.timestamp;
        receiver.paymentCount = receiver.paymentCount - 1;
        _transferMoney(receiver.assetAddress, receiver.amount, receiver.receiverAddress);
    }

    function _transferMoney(address erc20Address, uint256 amount, address receiverAddress) internal {
        IERC20 asset = IERC20(erc20Address);
        uint256 balance = asset.balanceOf(address(this));
        if (balance < amount) {
            revert InsufficientBalance();
        }
        asset.safeTransfer(receiverAddress, amount);
    }

    function addAssets(VaultStorage storage vaultStorage, address[] memory assetAddresses)
        external
        onlyInitialized(vaultStorage)
    {
        if (vaultStorage.addingAssetsDisabled) {
            revert AddingAssetsDisabled();
        }
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (!vaultStorage.whiteList.isAssetWhiteListed(assetAddresses[i])) {
                revert NotWhiteListed();
            }
            vaultStorage.assets.add(assetAddresses[i]);
        }
    }

    function disableAddingAssets(VaultStorage storage vaultStorage) external onlyInitialized(vaultStorage) {
        vaultStorage.addingAssetsDisabled = true;
    }

    function removeAssets(VaultStorage storage vaultStorage, address[] memory assetAddresses)
        external
        onlyInitialized(vaultStorage)
    {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            vaultStorage.assets.remove(assetAddresses[i]);
        }
    }

    function addStableCoins(VaultStorage storage vaultStorage, address[] memory stableCoinAddresses)
        external
        onlyInitialized(vaultStorage)
    {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (!vaultStorage.whiteList.isStableCoinWhiteListed(stableCoinAddresses[i])) {
                revert NotWhiteListed();
            }
            vaultStorage.stableCoins.add(stableCoinAddresses[i]);
        }
    }

    function removeStableCoins(VaultStorage storage vaultStorage, address[] memory stableCoinAddresses)
        external
        onlyInitialized(vaultStorage)
    {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            vaultStorage.stableCoins.remove(stableCoinAddresses[i]);
        }
    }

    function getAssets(VaultStorage storage vaultStorage) external view returns (address[] memory) {
        return vaultStorage.assets.values();
    }

    function getStableCoins(VaultStorage storage vaultStorage) external view returns (address[] memory) {
        return vaultStorage.stableCoins.values();
    }

    function checkAsset(VaultStorage storage logicStorage, address assetAddress) external view {
        if (logicStorage.assets.contains(assetAddress) || logicStorage.stableCoins.contains(assetAddress)) {
            return;
        }
        revert NotWhiteListed();
    }
}
