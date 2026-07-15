// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {
    AlreadyInitialized,
    AddressZero,
    AmountIsZero,
    NotInitialized,
    InsufficientBalance
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Guard, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultStorage} from "./Storages.sol";
import {
    IBittyV1Vault,
    ReceiverNotFound,
    ReceiverNameAlreadyExists,
    ReceiverImmutable,
    ReceiverPaymentCountZero,
    ReceiverTriggerError,
    ReceiverNotStartYet,
    ReceiverStartTimestampInPast,
    ReceiverInInterval,
    AddingAssetsDisabled,
    ReceiverIntervalTooShort,
    AssetAddressNotContract,
    NewReceiverProtectionOutOfRange,
    ReceiverProtectionNotEnded,
    PayMoreThanReceiverAmount,
    PayReceiverAmountTriggerEmpty,
    QuickPayAssetNotStableCoin,
    QuickPayExceedsMax,
    QuickPayInInterval
} from "../interfaces/IBittyV1Vault.sol";

library VaultLogic {
    /**
     * The vault will be drained by one attack in a very short time if no this protection.
     * @dev this is a protection for the vault.
     */
    uint256 constant RECEIVER_MINIMAL_INTERVAL = 1 days;

    /**
     * To protect the vault owner, the longer it is, the harder to attack the owner.
     * The RECEIVER_NEW_PROTECTION_MIN is actually RECEIVER_MINIMAL_INTERVAL.
     * @dev this is a protection for the vault.
     */
    uint256 constant RECEIVER_NEW_PROTECTION_MAX = 30 days;

    /**
     * Default quick-pay per-payment cap (in whole tokens) and minimum interval. The owner
     * can change both at any time via {setQuickPayLimit}.
     */
    uint64 constant QUICK_PAY_DEFAULT_MAX_WHOLE_TOKENS = 1000;
    uint64 constant QUICK_PAY_DEFAULT_INTERVAL = 1 days;

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
        vaultStorage.guard = IBittyV1Guard(guardAddress);
        vaultStorage.isInitialized = true;
        vaultStorage.quickPayMaxWholeTokens = QUICK_PAY_DEFAULT_MAX_WHOLE_TOKENS;
        vaultStorage.quickPayInterval = QUICK_PAY_DEFAULT_INTERVAL;
    }

    function addReceiver(VaultStorage storage vaultStorage, string memory name, IBittyV1Vault.Receiver memory receiver)
        external
        onlyInitialized(vaultStorage)
    {
        if (vaultStorage.receivers[name].amount != 0) {
            revert ReceiverNameAlreadyExists();
        }
        if (receiver.startTimestamp < block.timestamp) {
            revert ReceiverStartTimestampInPast();
        }
        _checkReceiver(receiver);
        vaultStorage.receivers[name] = receiver;
        if (vaultStorage.newReceiverProtection != 0) {
            vaultStorage.newReceiverProtectionTimestamps[name] = block.timestamp + vaultStorage.newReceiverProtection;
        }
        emit IBittyV1Vault.ReceiverAdded(name, receiver);
    }

    function getReceiverAddress(VaultStorage storage vaultStorage, string memory name) external view returns (address) {
        return vaultStorage.receivers[name].receiverAddress;
    }

    function changeReceiverAddress(VaultStorage storage vaultStorage, string memory name, address newReceiverAddress)
        external
        onlyInitialized(vaultStorage)
    {
        IBittyV1Vault.Receiver storage receiver = vaultStorage.receivers[name];
        if (receiver.isImmutable) {
            revert ReceiverImmutable();
        }
        if (newReceiverAddress == address(0)) {
            revert AddressZero();
        }
        address oldReceiverAddress = receiver.receiverAddress;
        receiver.receiverAddress = newReceiverAddress;
        emit IBittyV1Vault.ReceiverAddressChanged(name, oldReceiverAddress, newReceiverAddress);
    }

    function updateReceiver(
        VaultStorage storage vaultStorage,
        string memory name,
        IBittyV1Vault.Receiver memory receiver
    ) external onlyInitialized(vaultStorage) {
        IBittyV1Vault.Receiver memory existing = vaultStorage.receivers[name];
        if (existing.receiverAddress == address(0)) {
            revert ReceiverNotFound();
        }
        if (existing.isImmutable) {
            revert ReceiverImmutable();
        }
        _checkReceiver(receiver);
        vaultStorage.receivers[name] = receiver;
        emit IBittyV1Vault.ReceiverUpdated(name, receiver);
    }

    function _checkReceiver(IBittyV1Vault.Receiver memory receiver) internal view {
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
        if (receiver.paymentCount > 1 && receiver.paymentInterval < RECEIVER_MINIMAL_INTERVAL) {
            revert ReceiverIntervalTooShort();
        }
    }

    function removeReceiver(VaultStorage storage vaultStorage, string memory name)
        external
        onlyInitialized(vaultStorage)
    {
        delete vaultStorage.receivers[name];
        delete vaultStorage.newReceiverProtectionTimestamps[name];
        delete vaultStorage.lastReceiveTimestamps[name];
        emit IBittyV1Vault.ReceiverRemoved(name);
    }

    function setNewReceiverProtection(VaultStorage storage vaultStorage, uint256 newReceiverProtection)
        external
        onlyInitialized(vaultStorage)
    {
        if (newReceiverProtection > RECEIVER_NEW_PROTECTION_MAX) {
            revert NewReceiverProtectionOutOfRange();
        }
        vaultStorage.newReceiverProtection = newReceiverProtection;
        emit IBittyV1Vault.NewReceiverProtectionSet(newReceiverProtection);
    }

    /**
     * @notice Set the quick-pay per-payment cap (in whole tokens) and minimum interval.
     * @dev Effective immediately. Access control (owner-only) is enforced by the facade.
     */
    function setQuickPayLimit(VaultStorage storage vaultStorage, uint256 maxWholeTokens, uint256 interval)
        external
        onlyInitialized(vaultStorage)
    {
        vaultStorage.quickPayMaxWholeTokens = uint64(maxWholeTokens);
        vaultStorage.quickPayInterval = uint64(interval);
        emit IBittyV1Vault.QuickPayLimitSet(maxWholeTokens, interval);
    }

    /**
     * @notice Send stablecoin from the vault's balance straight to `to`, without needing a
     * registered receiver.
     * @dev Rate-limited discretionary payment. Access control (a dedicated quick-pay role,
     * separate from the owner) is enforced by the facade. The asset must be a stablecoin
     * registered on this vault; `amount` may not exceed `quickPayMaxWholeTokens` scaled by
     * the token's decimals; and at most one quick-pay is allowed per `quickPayInterval` on a
     * single shared clock, bounding total outflow via this path. Paid from the vault's idle
     * balance.
     */
    function quickPay(VaultStorage storage vaultStorage, address stableCoin, address to, uint256 amount)
        external
        onlyInitialized(vaultStorage)
    {
        if (to == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        if (!vaultStorage.stableCoins.contains(stableCoin)) {
            revert QuickPayAssetNotStableCoin();
        }

        uint256 maxUnits = vaultStorage.quickPayMaxWholeTokens * (10 ** IERC20Metadata(stableCoin).decimals());
        if (amount > maxUnits) {
            revert QuickPayExceedsMax();
        }

        uint256 last = vaultStorage.lastQuickPayTimestamp;
        if (last != 0 && block.timestamp - last < vaultStorage.quickPayInterval) {
            revert QuickPayInInterval();
        }

        vaultStorage.lastQuickPayTimestamp = uint128(block.timestamp);
        IERC20(stableCoin).safeTransfer(to, amount);
        emit IBittyV1Vault.QuickPaid(stableCoin, to, amount);
    }

    function getQuickPayLimit(VaultStorage storage vaultStorage)
        external
        view
        returns (uint256 maxWholeTokens, uint256 interval, uint256 lastTimestamp)
    {
        return (vaultStorage.quickPayMaxWholeTokens, vaultStorage.quickPayInterval, vaultStorage.lastQuickPayTimestamp);
    }

    function payReceiver(VaultStorage storage vaultStorage, string memory name) external onlyInitialized(vaultStorage) {
        IBittyV1Vault.Receiver storage receiver = vaultStorage.receivers[name];
        if (receiver.trigger != address(0) && msg.sender != receiver.trigger) {
            revert ReceiverTriggerError();
        }
        _payReceiver(vaultStorage, receiver, name, receiver.amount);
    }

    function payReceiverAmount(VaultStorage storage vaultStorage, string memory name, uint256 amount)
        external
        onlyInitialized(vaultStorage)
    {
        IBittyV1Vault.Receiver storage receiver = vaultStorage.receivers[name];
        if (receiver.amount < amount) {
            revert PayMoreThanReceiverAmount();
        }
        if (receiver.trigger == address(0)) {
            revert PayReceiverAmountTriggerEmpty();
        }
        if (msg.sender != receiver.trigger) {
            revert ReceiverTriggerError();
        }
        _payReceiver(vaultStorage, receiver, name, amount);
    }

    function _payReceiver(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.Receiver storage receiver,
        string memory name,
        uint256 payAmount
    ) internal {
        _accrueReceiverPayment(vaultStorage, receiver, name);
        uint256 paidAmount = _transferMoney(
            receiver.assetAddress, payAmount, receiver.receiverAddress, receiver.payWithInsufficientBalance
        );
        emit IBittyV1Vault.ReceiverPaid(
            name, receiver.receiverAddress, receiver.assetAddress, paidAmount, receiver.paymentCount
        );
    }

    /**
     * @dev Runs every eligibility check for a scheduled receiver payment and applies its
     * state effects (advance the interval clock, clear the new-receiver time-lock, and
     * consume one payment) — but performs no token transfer. Shared by the normal
     * pay-from-vault-balance path and the on-behalf pay-from-yield path so both honour
     * identical rules and checks-effects-interactions ordering.
     */
    function _accrueReceiverPayment(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.Receiver storage receiver,
        string memory name
    ) internal {
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
            receiver.paymentInterval != 0 && vaultStorage.lastReceiveTimestamps[name] > 0
                && block.timestamp - vaultStorage.lastReceiveTimestamps[name] < receiver.paymentInterval
        ) {
            revert ReceiverInInterval();
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
    }

    /**
     * @notice Accrue a scheduled receiver payment that will be settled by pulling the
     * asset directly out of a yield position (paid on-behalf, so the asset is delivered
     * to the receiver without ever touching this vault — see {payReceiverFromStaking} /
     * {payReceiverFromLending}).
     * @dev Enforces the same trigger authorization as {payReceiver} and runs all
     * eligibility checks + state effects up front (checks-effects-interactions), then
     * returns the details the facade needs to perform the on-behalf withdrawal. The
     * yield adapter delivers exactly `payAmount`, so {ReceiverPaid} is emitted here.
     * @return receiverAddress The configured receiver that must receive the funds.
     * @return assetAddress The asset the receiver is paid in.
     * @return payAmount The full scheduled payment amount to pull from the yield position.
     */
    function accrueReceiverPaymentOnBehalf(VaultStorage storage vaultStorage, string memory name)
        external
        onlyInitialized(vaultStorage)
        returns (address receiverAddress, address assetAddress, uint256 payAmount)
    {
        IBittyV1Vault.Receiver storage receiver = vaultStorage.receivers[name];
        if (receiver.trigger != address(0) && msg.sender != receiver.trigger) {
            revert ReceiverTriggerError();
        }
        payAmount = receiver.amount;
        _accrueReceiverPayment(vaultStorage, receiver, name);
        receiverAddress = receiver.receiverAddress;
        assetAddress = receiver.assetAddress;
        emit IBittyV1Vault.ReceiverPaid(name, receiverAddress, assetAddress, payAmount, receiver.paymentCount);
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
