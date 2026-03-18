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
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultStorage} from "./Storages.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {
    IVault,
    ReceiverNotFound,
    ReceiverImmutable,
    ReceiverPaymentCountZero,
    ReceiverTriggerError,
    ReceiverNotStartYet,
    ReceiverInDuration,
    ETHBalanceNotEnough,
    WETHBalanceNotEnough,
    AddingAssetsDisabled
} from "../interfaces/IVault.sol";

library VaultLogic {
    uint256 public constant RECEIVER_UPDATE_DELAY = 7 days;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    modifier onlyInitialized(VaultStorage storage logicStorage) {
        _onlyInitialized(logicStorage);
        _;
    }

    function _onlyInitialized(VaultStorage storage logicStorage) private view {
        if (!logicStorage.isInitialized) {
            revert NotInitialized();
        }
    }

    modifier onlyNotInitialized(VaultStorage storage logicStorage) {
        _onlyNotInitialized(logicStorage);
        _;
    }

    function _onlyNotInitialized(VaultStorage storage logicStorage) private view {
        if (logicStorage.isInitialized) {
            revert AlreadyInitialized();
        }
    }

    function initialize(VaultStorage storage logicStorage, address weth, address whiteListAddress)
        external
        onlyNotInitialized(logicStorage)
    {
        if (weth == address(0)) {
            revert AddressZero();
        }
        logicStorage.weth = weth;
        if (whiteListAddress == address(0)) {
            revert AddressZero();
        }
        logicStorage.whiteList = IWhiteList(whiteListAddress);
        logicStorage.isInitialized = true;
    }

    function addReceiver(VaultStorage storage logicStorage, string memory name, IVault.Receiver memory receiver)
        external
        onlyInitialized(logicStorage)
    {
        _checkReceiver(receiver);
        logicStorage.receivers[name] = receiver;
    }

    function getReceiverAddress(VaultStorage storage logicStorage, string memory name) external view returns (address) {
        return logicStorage.receivers[name].receiverAddress;
    }

    function changeReceiverAddress(VaultStorage storage logicStorage, string memory name, address newReceiverAddress)
        external
        onlyInitialized(logicStorage)
    {
        IVault.Receiver storage receiver = logicStorage.receivers[name];
        if (receiver.isImmutable) {
            revert ReceiverImmutable();
        }
        if (newReceiverAddress == address(0)) {
            revert AddressZero();
        }
        receiver.receiverAddress = newReceiverAddress;
    }

    function updateReceiver(VaultStorage storage logicStorage, string memory name, IVault.Receiver memory receiver)
        external
        onlyInitialized(logicStorage)
    {
        IVault.Receiver memory existing = logicStorage.receivers[name];
        if (existing.receiverAddress == address(0)) {
            revert ReceiverNotFound();
        }
        if (existing.isImmutable) {
            revert ReceiverImmutable();
        }
        _checkReceiver(receiver);
        logicStorage.receivers[name] = receiver;
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
    }

    function removeReceiver(VaultStorage storage logicStorage, string memory name)
        external
        onlyInitialized(logicStorage)
    {
        delete logicStorage.receivers[name];
    }

    function ETHToWETH(VaultStorage storage logicStorage, uint256 amount) external onlyInitialized(logicStorage) {
        uint256 ethBalance = address(this).balance;
        if (ethBalance < amount) {
            revert ETHBalanceNotEnough();
        }
        WETH(payable(logicStorage.weth)).deposit{value: amount}();
    }

    function WETHToETH(VaultStorage storage logicStorage, uint256 amount) external onlyInitialized(logicStorage) {
        uint256 wethBalance = IERC20(logicStorage.weth).balanceOf(address(this));
        if (wethBalance < amount) {
            revert WETHBalanceNotEnough();
        }
        WETH(payable(logicStorage.weth)).withdraw(amount);
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
            receiver.durationTimestamp != 0
                && block.timestamp - receiver.lastReceiveTimestamp < receiver.durationTimestamp
        ) {
            revert ReceiverInDuration();
        }
        receiver.lastReceiveTimestamp = block.timestamp;
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

    function addAssets(VaultStorage storage logicStorage, address[] memory assetAddresses)
        external
        onlyInitialized(logicStorage)
    {
        if (logicStorage.addingAssetsDisabled) {
            revert AddingAssetsDisabled();
        }
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (!logicStorage.whiteList.isAssetWhiteListed(assetAddresses[i])) {
                revert NotWhiteListed();
            }
            logicStorage.assets.add(assetAddresses[i]);
        }
    }

    function disableAddingAssets(VaultStorage storage logicStorage) external onlyInitialized(logicStorage) {
        logicStorage.addingAssetsDisabled = true;
    }

    function removeAssets(VaultStorage storage logicStorage, address[] memory assetAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            logicStorage.assets.remove(assetAddresses[i]);
        }
    }

    function addStableCoins(VaultStorage storage logicStorage, address[] memory stableCoinAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (!logicStorage.whiteList.isStableCoinWhiteListed(stableCoinAddresses[i])) {
                revert NotWhiteListed();
            }
            logicStorage.stableCoins.add(stableCoinAddresses[i]);
        }
    }

    function removeStableCoins(VaultStorage storage logicStorage, address[] memory stableCoinAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            logicStorage.stableCoins.remove(stableCoinAddresses[i]);
        }
    }

    function getAssets(VaultStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.assets.values();
    }

    function getStableCoins(VaultStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.stableCoins.values();
    }

    function checkAsset(VaultStorage storage logicStorage, address assetAddress) external view {
        if (logicStorage.whiteList.isAssetWhiteListed(assetAddress) && logicStorage.assets.contains(assetAddress)) {
            return;
        }
        if (
            logicStorage.whiteList.isStableCoinWhiteListed(assetAddress)
                && logicStorage.stableCoins.contains(assetAddress)
        ) {
            return;
        }
        revert NotWhiteListed();
    }
}
