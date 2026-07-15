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
import {VaultStorage, MicroPaymentLimit} from "./Storages.sol";
import {
    IBittyV1Vault,
    ScheduledPaymentNotFound,
    ScheduledPaymentNameAlreadyExists,
    ScheduledPaymentImmutable,
    ScheduledPaymentPaymentCountZero,
    ScheduledPaymentTriggerError,
    ScheduledPaymentNotStartYet,
    ScheduledPaymentStartTimestampInPast,
    ScheduledPaymentInInterval,
    AddingAssetsDisabled,
    ScheduledPaymentIntervalTooShort,
    AssetAddressNotContract,
    NewAddressProtectionOutOfRange,
    NewAddressProtectionCannotDecrease,
    AddressProtectionNotEnded,
    PayMoreThanScheduledPaymentAmount,
    PayScheduledPaymentAmountTriggerEmpty,
    MicroPaymentAssetNotStableCoin,
    MicroPaymentExceedsMax,
    MicroPaymentInInterval,
    MicroPaymentPayerNotConfigured,
    MicroPaymentLimitOutOfRange,
    WhitelistedRecipientNotFound,
    WhitelistedRecipientNameAlreadyExists,
    WhitelistedRecipientAssetNotAllowed
} from "../interfaces/IBittyV1Vault.sol";

library VaultLogic {
    /**
     * The vault will be drained by one attack in a very short time if no this protection.
     * @dev this is a protection for the vault.
     */
    uint256 constant SCHEDULED_PAYMENT_MINIMAL_INTERVAL = 7 days;

    /**
     * To protect the vault owner, the longer it is, the harder to attack the owner. Applies to both
     * newly added scheduled payments and newly added whitelisted recipients.
     * @dev this is a protection for the vault.
     */
    uint256 constant NEW_ADDRESS_PROTECTION_MAX = 30 days;

    /**
     * Once protection is enabled it can never be lowered below this floor: a compromised owner key
     * cannot set it to 0 to add a payee and drain immediately. The real owner therefore always keeps
     * at least this long to notice and react (revoke the key / remove the payee) before any newly
     * introduced address becomes payable. 0 (fully disabled) is only the pre-opt-in default and can
     * never be re-established through {setNewAddressProtection}.
     */
    uint256 constant NEW_ADDRESS_PROTECTION_MIN = 1 days;

    /**
     * Hard bounds on every per-payer micro-payment limit. These are absolute: even the owner cannot
     * configure a payer above the cap or below the interval floor, so a compromised owner key can at
     * worst move {MICRO_PAYMENT_MAX_WHOLE_TOKENS} whole tokens per {MICRO_PAYMENT_MIN_INTERVAL} per
     * payer. The owner sets each payer's own (lower/looser) limit within these bounds.
     */
    uint64 constant MICRO_PAYMENT_MAX_WHOLE_TOKENS = 1000;
    uint64 constant MICRO_PAYMENT_MIN_INTERVAL = 1 days;

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
    }

    function addScheduledPayment(
        VaultStorage storage vaultStorage,
        string memory name,
        IBittyV1Vault.ScheduledPayment memory scheduledPayment
    ) external onlyInitialized(vaultStorage) {
        if (vaultStorage.scheduledPayments[name].amount != 0) {
            revert ScheduledPaymentNameAlreadyExists();
        }
        if (scheduledPayment.startTimestamp < block.timestamp) {
            revert ScheduledPaymentStartTimestampInPast();
        }
        _checkScheduledPayment(scheduledPayment);
        vaultStorage.scheduledPayments[name] = scheduledPayment;
        _armAddressProtection(vaultStorage, scheduledPayment.scheduledPaymentAddress);
        emit IBittyV1Vault.ScheduledPaymentAdded(name, scheduledPayment);
    }

    function getScheduledPaymentAddress(VaultStorage storage vaultStorage, string memory name)
        external
        view
        returns (address)
    {
        return vaultStorage.scheduledPayments[name].scheduledPaymentAddress;
    }

    function changeScheduledPaymentAddress(
        VaultStorage storage vaultStorage,
        string memory name,
        address newScheduledPaymentAddress
    ) external onlyInitialized(vaultStorage) {
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[name];
        if (scheduledPayment.isImmutable) {
            revert ScheduledPaymentImmutable();
        }
        if (newScheduledPaymentAddress == address(0)) {
            revert AddressZero();
        }
        address oldScheduledPaymentAddress = scheduledPayment.scheduledPaymentAddress;
        scheduledPayment.scheduledPaymentAddress = newScheduledPaymentAddress;
        _armAddressProtection(vaultStorage, newScheduledPaymentAddress);
        emit IBittyV1Vault.ScheduledPaymentAddressChanged(name, oldScheduledPaymentAddress, newScheduledPaymentAddress);
    }

    function updateScheduledPayment(
        VaultStorage storage vaultStorage,
        string memory name,
        IBittyV1Vault.ScheduledPayment memory scheduledPayment
    ) external onlyInitialized(vaultStorage) {
        IBittyV1Vault.ScheduledPayment memory existing = vaultStorage.scheduledPayments[name];
        if (existing.scheduledPaymentAddress == address(0)) {
            revert ScheduledPaymentNotFound();
        }
        if (existing.isImmutable) {
            revert ScheduledPaymentImmutable();
        }
        _checkScheduledPayment(scheduledPayment);
        vaultStorage.scheduledPayments[name] = scheduledPayment;
        _armAddressProtection(vaultStorage, scheduledPayment.scheduledPaymentAddress);
        emit IBittyV1Vault.ScheduledPaymentUpdated(name, scheduledPayment);
    }

    function _checkScheduledPayment(IBittyV1Vault.ScheduledPayment memory scheduledPayment) internal view {
        if (scheduledPayment.scheduledPaymentAddress == address(0)) {
            revert AddressZero();
        }
        if (scheduledPayment.assetAddress.code.length == 0) {
            revert AssetAddressNotContract();
        }
        if (scheduledPayment.amount == 0) {
            revert AmountIsZero();
        }
        if (scheduledPayment.paymentCount == 0) {
            revert ScheduledPaymentPaymentCountZero();
        }
        if (scheduledPayment.paymentCount > 1 && scheduledPayment.paymentInterval < SCHEDULED_PAYMENT_MINIMAL_INTERVAL)
        {
            revert ScheduledPaymentIntervalTooShort();
        }
    }

    function removeScheduledPayment(VaultStorage storage vaultStorage, string memory name)
        external
        onlyInitialized(vaultStorage)
    {
        address scheduledPaymentAddress = vaultStorage.scheduledPayments[name].scheduledPaymentAddress;
        delete vaultStorage.scheduledPayments[name];
        delete vaultStorage.newAddressProtectionTimestamps[scheduledPaymentAddress];
        delete vaultStorage.lastReceiveTimestamps[name];
        emit IBittyV1Vault.ScheduledPaymentRemoved(name);
    }

    function setNewAddressProtection(VaultStorage storage vaultStorage, uint256 newAddressProtection)
        external
        onlyInitialized(vaultStorage)
    {
        if (newAddressProtection < NEW_ADDRESS_PROTECTION_MIN || newAddressProtection > NEW_ADDRESS_PROTECTION_MAX) {
            revert NewAddressProtectionOutOfRange();
        }
        // Monotonic ratchet: the window can only be raised, never lowered. This makes the configured
        // window a real guarantee — a compromised owner key cannot weaken it (e.g. drop 30 days to 1)
        // to speed up draining. The trade-off is that reductions are impossible once set.
        if (newAddressProtection < vaultStorage.newAddressProtection) {
            revert NewAddressProtectionCannotDecrease();
        }
        vaultStorage.newAddressProtection = newAddressProtection;
        emit IBittyV1Vault.NewAddressProtectionSet(newAddressProtection);
    }

    /**
     * @notice Arm the shared address time-lock for a newly introduced payee `recipient`.
     * @dev No-op when protection is disabled. Never shortens an existing deadline (uses the max), so
     * introducing an already-protected address through another payment feature cannot reduce its
     * remaining lock.
     */
    function _armAddressProtection(VaultStorage storage vaultStorage, address recipient) internal {
        uint256 protection = vaultStorage.newAddressProtection;
        if (protection == 0) {
            return;
        }
        uint256 endsAt = block.timestamp + protection;
        if (endsAt > vaultStorage.newAddressProtectionTimestamps[recipient]) {
            vaultStorage.newAddressProtectionTimestamps[recipient] = endsAt;
        }
    }

    /**
     * @notice Enforce and clear the shared address time-lock before paying `recipient`.
     * @dev Reverts with {AddressProtectionNotEnded} while the window is still open; once elapsed the
     * deadline is cleared so the check is skipped on every subsequent payment. Shared by the scheduled
     * payment and whitelisted recipient pay paths — both key on the payee address.
     */
    function _clearAddressProtection(VaultStorage storage vaultStorage, address recipient) internal {
        uint256 endsAt = vaultStorage.newAddressProtectionTimestamps[recipient];
        if (endsAt > 0) {
            if (block.timestamp < endsAt) {
                revert AddressProtectionNotEnded();
            }
            delete vaultStorage.newAddressProtectionTimestamps[recipient];
        }
    }

    /**
     * @notice Set the per-payment cap (in whole tokens) and minimum interval for a single micro-payer.
     * @dev Effective immediately and scoped to `payer`. Access control (owner-only) is enforced by the
     * facade. Setting `maxWholeTokens` to 0 disables `payer`. When enabling a payer the values are
     * clamped to the hard bounds ({MICRO_PAYMENT_MAX_WHOLE_TOKENS}, {MICRO_PAYMENT_MIN_INTERVAL}): a
     * cap above the ceiling or an interval below the floor reverts, so even a compromised owner cannot
     * widen a payer past the absolute per-payer budget. Only the payer's cap and interval are touched;
     * the payer's last-payment clock is preserved.
     */
    function setMicroPaymentLimit(
        VaultStorage storage vaultStorage,
        address payer,
        uint256 maxWholeTokens,
        uint256 interval
    ) external onlyInitialized(vaultStorage) {
        if (payer == address(0)) {
            revert AddressZero();
        }
        if (maxWholeTokens > MICRO_PAYMENT_MAX_WHOLE_TOKENS) {
            revert MicroPaymentLimitOutOfRange();
        }
        // A non-zero (enabled) payer must also respect the interval floor; a 0 cap (disable) may pass
        // interval 0.
        if (maxWholeTokens > 0 && interval < MICRO_PAYMENT_MIN_INTERVAL) {
            revert MicroPaymentLimitOutOfRange();
        }
        MicroPaymentLimit storage limit = vaultStorage.microPaymentLimits[payer];
        limit.maxWholeTokens = uint64(maxWholeTokens);
        limit.interval = uint64(interval);
        emit IBittyV1Vault.MicroPaymentLimitSet(payer, maxWholeTokens, interval);
    }

    /**
     * @notice Send stablecoin from the vault's balance straight to `to`, without needing a
     * registered scheduledPayment.
     * @dev Rate-limited discretionary payment, scoped to the caller. Role gating (a dedicated
     * micro-payment role, separate from the owner) is enforced by the facade; here the caller
     * (`msg.sender`) must additionally have a cap the owner configured for its address, so only a
     * specifically configured payer can spend. The asset must be a stablecoin registered on this
     * vault; `amount` may not exceed the caller's own cap scaled by the token's decimals; and at most
     * one micro-payment is allowed per the caller's own interval on the caller's own clock, bounding
     * each payer's outflow independently. Paid from the vault's idle balance.
     */
    function payMicro(VaultStorage storage vaultStorage, address stableCoin, address to, uint256 amount)
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
            revert MicroPaymentAssetNotStableCoin();
        }

        MicroPaymentLimit storage limit = vaultStorage.microPaymentLimits[msg.sender];
        if (limit.maxWholeTokens == 0) {
            revert MicroPaymentPayerNotConfigured();
        }

        uint256 maxUnits = uint256(limit.maxWholeTokens) * (10 ** IERC20Metadata(stableCoin).decimals());
        if (amount > maxUnits) {
            revert MicroPaymentExceedsMax();
        }

        uint256 last = limit.lastTimestamp;
        if (last != 0 && block.timestamp - last < limit.interval) {
            revert MicroPaymentInInterval();
        }

        limit.lastTimestamp = uint128(block.timestamp);
        IERC20(stableCoin).safeTransfer(to, amount);
        emit IBittyV1Vault.MicroPaid(stableCoin, to, amount);
    }

    function getMicroPaymentLimit(VaultStorage storage vaultStorage, address payer)
        external
        view
        returns (uint256 maxWholeTokens, uint256 interval, uint256 lastTimestamp)
    {
        MicroPaymentLimit storage limit = vaultStorage.microPaymentLimits[payer];
        return (limit.maxWholeTokens, limit.interval, limit.lastTimestamp);
    }

    /**
     * @notice Add a whitelisted recipient. Reverts if `name` already exists.
     * @dev Access control (owner-only) is enforced by the facade.
     */
    function addWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        string memory name,
        address recipient,
        address allowedAsset
    ) external onlyInitialized(vaultStorage) {
        if (recipient == address(0)) {
            revert AddressZero();
        }
        if (vaultStorage.whitelistedRecipients[name].recipient != address(0)) {
            revert WhitelistedRecipientNameAlreadyExists();
        }
        vaultStorage.whitelistedRecipients[name] =
            IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset});
        _armAddressProtection(vaultStorage, recipient);
        emit IBittyV1Vault.WhitelistedRecipientSet(name, recipient, allowedAsset);
    }

    /**
     * @notice Update an existing whitelisted recipient. Reverts if `name` does not exist.
     * @dev Access control (owner-only) is enforced by the facade.
     */
    function updateWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        string memory name,
        address recipient,
        address allowedAsset
    ) external onlyInitialized(vaultStorage) {
        if (recipient == address(0)) {
            revert AddressZero();
        }
        if (vaultStorage.whitelistedRecipients[name].recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        vaultStorage.whitelistedRecipients[name] =
            IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset});
        _armAddressProtection(vaultStorage, recipient);
        emit IBittyV1Vault.WhitelistedRecipientSet(name, recipient, allowedAsset);
    }

    /**
     * @notice Remove a whitelisted recipient. Reverts if `name` does not exist.
     * @dev Access control (owner-only) is enforced by the facade.
     */
    function removeWhitelistedRecipient(VaultStorage storage vaultStorage, string memory name)
        external
        onlyInitialized(vaultStorage)
    {
        address recipient = vaultStorage.whitelistedRecipients[name].recipient;
        if (recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        delete vaultStorage.whitelistedRecipients[name];
        delete vaultStorage.newAddressProtectionTimestamps[recipient];
        emit IBittyV1Vault.WhitelistedRecipientRemoved(name);
    }

    /**
     * @notice Pay a whitelisted recipient a discretionary amount from the vault's balance.
     * @dev Access control (owner-only) is enforced by the facade. The asset must match the entry's
     * allowedAsset unless that is address(0) (any asset). Not rate-limited — recipients are vetted
     * by the owner at set time — but a newly added recipient is time-locked by newAddressProtection
     * until its window elapses. Paid from the vault's idle balance.
     */
    function sendToWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        string memory name,
        address asset,
        uint256 amount
    ) external onlyInitialized(vaultStorage) {
        if (amount == 0) {
            revert AmountIsZero();
        }
        IBittyV1Vault.WhitelistedRecipient memory entry = vaultStorage.whitelistedRecipients[name];
        if (entry.recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        if (entry.allowedAsset != address(0) && asset != entry.allowedAsset) {
            revert WhitelistedRecipientAssetNotAllowed();
        }
        _clearAddressProtection(vaultStorage, entry.recipient);
        IERC20(asset).safeTransfer(entry.recipient, amount);
        emit IBittyV1Vault.WhitelistedRecipientPaid(name, entry.recipient, asset, amount);
    }

    function getWhitelistedRecipient(VaultStorage storage vaultStorage, string memory name)
        external
        view
        returns (address recipient, address allowedAsset)
    {
        IBittyV1Vault.WhitelistedRecipient memory entry = vaultStorage.whitelistedRecipients[name];
        return (entry.recipient, entry.allowedAsset);
    }

    function payScheduled(VaultStorage storage vaultStorage, string memory name)
        external
        onlyInitialized(vaultStorage)
    {
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[name];
        if (scheduledPayment.trigger != address(0) && msg.sender != scheduledPayment.trigger) {
            revert ScheduledPaymentTriggerError();
        }
        _payScheduled(vaultStorage, scheduledPayment, name, scheduledPayment.amount);
    }

    function payScheduledAmount(VaultStorage storage vaultStorage, string memory name, uint256 amount)
        external
        onlyInitialized(vaultStorage)
    {
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[name];
        if (scheduledPayment.amount < amount) {
            revert PayMoreThanScheduledPaymentAmount();
        }
        if (scheduledPayment.trigger == address(0)) {
            revert PayScheduledPaymentAmountTriggerEmpty();
        }
        if (msg.sender != scheduledPayment.trigger) {
            revert ScheduledPaymentTriggerError();
        }
        _payScheduled(vaultStorage, scheduledPayment, name, amount);
    }

    function _payScheduled(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment storage scheduledPayment,
        string memory name,
        uint256 payAmount
    ) internal {
        _accrueScheduledPaymentPayment(vaultStorage, scheduledPayment, name);
        uint256 paidAmount = _transferMoney(
            scheduledPayment.assetAddress,
            payAmount,
            scheduledPayment.scheduledPaymentAddress,
            scheduledPayment.payWithInsufficientBalance
        );
        emit IBittyV1Vault.ScheduledPaymentPaid(
            name,
            scheduledPayment.scheduledPaymentAddress,
            scheduledPayment.assetAddress,
            paidAmount,
            scheduledPayment.paymentCount
        );
    }

    /**
     * @dev Runs every eligibility check for a scheduled scheduledPayment payment and applies its
     * state effects (advance the interval clock, clear the new-scheduledPayment time-lock, and
     * consume one payment) — but performs no token transfer. Shared by the normal
     * pay-from-vault-balance path and the on-behalf pay-from-yield path so both honour
     * identical rules and checks-effects-interactions ordering.
     */
    function _accrueScheduledPaymentPayment(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment storage scheduledPayment,
        string memory name
    ) internal {
        if (scheduledPayment.amount == 0) {
            revert ScheduledPaymentNotFound();
        }
        if (scheduledPayment.paymentCount == 0) {
            revert ScheduledPaymentPaymentCountZero();
        }
        if (scheduledPayment.startTimestamp > block.timestamp) {
            revert ScheduledPaymentNotStartYet();
        }
        if (
            scheduledPayment.paymentInterval != 0 && vaultStorage.lastReceiveTimestamps[name] > 0
                && block.timestamp - vaultStorage.lastReceiveTimestamps[name] < scheduledPayment.paymentInterval
        ) {
            revert ScheduledPaymentInInterval();
        }
        _clearAddressProtection(vaultStorage, scheduledPayment.scheduledPaymentAddress);
        vaultStorage.lastReceiveTimestamps[name] = block.timestamp;
        // type(uint8).max is the "unlimited" sentinel: an uncapped recurring scheduled payment that never
        // decrements and so never runs out.
        if (scheduledPayment.paymentCount != type(uint8).max) {
            scheduledPayment.paymentCount = scheduledPayment.paymentCount - 1;
        }
    }

    /**
     * @notice Accrue a scheduled scheduledPayment payment that will be settled by pulling the
     * asset directly out of a yield position (paid on-behalf, so the asset is delivered
     * to the scheduledPayment without ever touching this vault — see {payScheduledFromStaking} /
     * {payScheduledFromLending}).
     * @dev Enforces the same trigger authorization as {payScheduled} and runs all
     * eligibility checks + state effects up front (checks-effects-interactions), then
     * returns the details the facade needs to perform the on-behalf withdrawal. The
     * yield adapter delivers exactly `payAmount`, so {ScheduledPaymentPaid} is emitted here.
     * @return scheduledPaymentAddress The configured scheduledPayment that must receive the funds.
     * @return assetAddress The asset the scheduledPayment is paid in.
     * @return payAmount The full scheduled payment amount to pull from the yield position.
     */
    function accrueScheduledPaymentOnBehalf(VaultStorage storage vaultStorage, string memory name)
        external
        onlyInitialized(vaultStorage)
        returns (address scheduledPaymentAddress, address assetAddress, uint256 payAmount)
    {
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[name];
        if (scheduledPayment.trigger != address(0) && msg.sender != scheduledPayment.trigger) {
            revert ScheduledPaymentTriggerError();
        }
        payAmount = scheduledPayment.amount;
        _accrueScheduledPaymentPayment(vaultStorage, scheduledPayment, name);
        scheduledPaymentAddress = scheduledPayment.scheduledPaymentAddress;
        assetAddress = scheduledPayment.assetAddress;
        emit IBittyV1Vault.ScheduledPaymentPaid(
            name, scheduledPaymentAddress, assetAddress, payAmount, scheduledPayment.paymentCount
        );
    }

    function _transferMoney(
        address erc20Address,
        uint256 amount,
        address scheduledPaymentAddress,
        bool payWithInsufficientBalance
    ) internal returns (uint256 paidAmount) {
        IERC20 asset = IERC20(erc20Address);
        uint256 balance = asset.balanceOf(address(this));
        if (!payWithInsufficientBalance && balance < amount) {
            revert InsufficientBalance();
        }
        paidAmount = balance < amount ? balance : amount;
        asset.safeTransfer(scheduledPaymentAddress, paidAmount);
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
