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
import {IGuard, NotRegistered} from "guard-contracts/src/interfaces/IGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultStorage} from "./Storages.sol";
import {
    IVault,
    ReceiverNotFound,
    ReceiverNameAlreadyExists,
    ReceiverImmutable,
    ReceiverPaymentCountZero,
    ReceiverTriggerError,
    ReceiverNotStartYet,
    ReceiverInDuration,
    AddingAssetsDisabled,
    ReceiverDurationTooShort,
    AssetAddressNotContract,
    NewReceiverProtectionOutOfRange,
    ReceiverProtectionNotEnded,
    PayMoreThanReceiverAmount,
    PayReceiverAmountTriggerEmpty
} from "../interfaces/IVault.sol";

library VaultLogic {
    /**
     * The vault will be drained by one attack in a very short time if no this protection.
     * @dev this is a protection for the vault.
     */
    uint256 constant RECEIVER_MINIMAL_DURATION = 1 days;

    /**
     * To protect the vault owner, the longer it is, the harder to attack the owner.
     * The RECEIVER_NEW_PROTECTION_MIN is actually RECEIVER_MINIMAL_DURATION.
     * @dev this is a protection for the vault.
     */
    uint256 constant RECEIVER_NEW_PROTECTION_MAX = 30 days;

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

    function initialize(VaultStorage storage vaultStorage, address guardAddress)
        external
        onlyNotInitialized(vaultStorage)
    {
        vaultStorage.guard = IGuard(guardAddress);
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
        if (vaultStorage.newReceiverProtection != 0) {
            vaultStorage.newReceiverProtectionTimestamps[name] = block.timestamp + vaultStorage.newReceiverProtection;
        }
        emit IVault.ReceiverAdded(name, receiver);
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
        address oldReceiverAddress = receiver.receiverAddress;
        receiver.receiverAddress = newReceiverAddress;
        emit IVault.ReceiverAddressChanged(name, oldReceiverAddress, newReceiverAddress);
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
        emit IVault.ReceiverUpdated(name, receiver);
    }

    function _checkReceiver(IVault.Receiver memory receiver) internal view {
        if (receiver.receiverAddress == address(0)) {
            revert AddressZero();
        }
        if (receiver.assetAddress.code.length == 0) {
            revert AssetAddressNotContract();
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
        delete vaultStorage.newReceiverProtectionTimestamps[name];
        emit IVault.ReceiverRemoved(name);
    }

    function setNewReceiverProtection(VaultStorage storage vaultStorage, uint256 newReceiverProtection)
        external
        onlyInitialized(vaultStorage)
    {
        if (newReceiverProtection > RECEIVER_NEW_PROTECTION_MAX) {
            revert NewReceiverProtectionOutOfRange();
        }
        vaultStorage.newReceiverProtection = newReceiverProtection;
        emit IVault.NewReceiverProtectionSet(newReceiverProtection);
    }

    function payReceiver(VaultStorage storage vaultStorage, string memory name) external {
        IVault.Receiver storage receiver = vaultStorage.receivers[name];
        if (receiver.trigger != address(0) && msg.sender != receiver.trigger) {
            revert ReceiverTriggerError();
        }
        _payReceiver(vaultStorage, receiver, name);
    }

    function payReceiverAmount(VaultStorage storage vaultStorage, string memory name, uint256 amount) external {
        IVault.Receiver storage receiver = vaultStorage.receivers[name];
        if (receiver.amount < amount) {
            revert PayMoreThanReceiverAmount();
        }
        if (receiver.trigger == address(0)) {
            revert PayReceiverAmountTriggerEmpty();
        }
        _payReceiver(vaultStorage, receiver, name);
    }

    function _payReceiver(VaultStorage storage vaultStorage, IVault.Receiver storage receiver, string memory name)
        internal
    {
        if (receiver.amount == 0) {
            revert ReceiverNotFound();
        }
        if (receiver.paymentCount == 0) {
            revert ReceiverPaymentCountZero();
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
        if (vaultStorage.newReceiverProtectionTimestamps[name] > 0) {
            if (block.timestamp < vaultStorage.newReceiverProtectionTimestamps[name]) {
                revert ReceiverProtectionNotEnded();
            } else {
                delete vaultStorage.newReceiverProtectionTimestamps[name];
            }
        }
        vaultStorage.lastReceiveTimestamps[name] = block.timestamp;
        receiver.paymentCount = receiver.paymentCount - 1;
        uint256 paidAmount = _transferMoney(
            receiver.assetAddress, receiver.amount, receiver.receiverAddress, receiver.payWithInsufficientBalance
        );
        emit IVault.ReceiverPaid(
            name, receiver.receiverAddress, receiver.assetAddress, paidAmount, receiver.paymentCount
        );
    }

    function _transferMoney(
        address erc20Address,
        uint256 amount,
        address receiverAddress,
        bool payWithInsufficientBalance
    ) internal returns (uint256 paidAmount) {
        IERC20 asset = IERC20(erc20Address);
        uint256 balance = asset.balanceOf(address(this));
        if (!payWithInsufficientBalance && balance < amount) {
            revert InsufficientBalance();
        }
        paidAmount = balance < amount ? balance : amount;
        asset.safeTransfer(receiverAddress, paidAmount);
    }

    function addAssets(VaultStorage storage vaultStorage, address[] memory assetAddresses)
        external
        onlyInitialized(vaultStorage)
    {
        if (vaultStorage.addingAssetsDisabled) {
            revert AddingAssetsDisabled();
        }
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (vaultStorage.guard.isAssetRegistered(assetAddresses[i])) {
                vaultStorage.assets.add(assetAddresses[i]);
            } else if (vaultStorage.guard.isStableCoinRegistered(assetAddresses[i])) {
                vaultStorage.stableCoins.add(assetAddresses[i]);
            } else {
                revert NotRegistered();
            }
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
            if (vaultStorage.assets.contains(assetAddresses[i])) {
                vaultStorage.assets.remove(assetAddresses[i]);
            } else if (vaultStorage.stableCoins.contains(assetAddresses[i])) {
                vaultStorage.stableCoins.remove(assetAddresses[i]);
            } else {
                revert NotRegistered();
            }
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
        revert NotRegistered();
    }
}
