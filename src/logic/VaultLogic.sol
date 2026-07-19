// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {
    AlreadyInitialized,
    AddressZero,
    AmountIsZero,
    NotInitialized,
    InsufficientBalance,
    TransferFailed,
    ReentrantCall
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {IBittyV1PaymentManager} from "../interfaces/IBittyV1PaymentManager.sol";
import {IBittyV1Guard, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {VaultStorage, PendingSend} from "./Storages.sol";
import {
    IBittyV1Vault,
    ScheduledPaymentNotFound,
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
    WhitelistedRecipientNotFound,
    WhitelistedRecipientAssetNotAllowed,
    PaymentNotApproved,
    NotPendingApproval,
    NotProposalOwner,
    PendingSendNotFound,
    SendingDisabled
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

    function send(VaultStorage storage vaultStorage, address recipient, address asset, uint256 amount)
        external
        onlyInitialized(vaultStorage)
    {
        if (vaultStorage.sendingDisabled) {
            revert SendingDisabled();
        }
        _payOut(vaultStorage, asset, amount, recipient);
    }

    function disableSending(VaultStorage storage vaultStorage) external onlyInitialized(vaultStorage) {
        vaultStorage.sendingDisabled = true;
    }

    function isSendingDisabled(VaultStorage storage vaultStorage) external view returns (bool) {
        return vaultStorage.sendingDisabled;
    }

    /**
     * @notice Queue a payment-manager-proposed one-off send for owner approval. Access control
     * (payment-manager) is enforced by the facade.
     */
    function proposeSend(VaultStorage storage vaultStorage, address recipient, address asset, uint256 amount)
        external
        onlyInitialized(vaultStorage)
        returns (uint256 id)
    {
        if (vaultStorage.sendingDisabled) {
            revert SendingDisabled();
        }
        id = vaultStorage.nextPendingSendId++;
        vaultStorage.pendingSends[id] =
            PendingSend({proposer: msg.sender, recipient: recipient, asset: asset, amount: amount});
        emit IBittyV1PaymentManager.SendProposed(id, msg.sender, recipient, asset, amount);
    }

    /**
     * @notice Owner: execute a queued one-off send. Access control (owner-only) is enforced by the
     * facade. Re-checks {sendingDisabled} in case it was disabled after the proposal.
     */
    function approveSend(VaultStorage storage vaultStorage, uint256 id) external onlyInitialized(vaultStorage) {
        PendingSend memory ps = vaultStorage.pendingSends[id];
        if (ps.proposer == address(0)) {
            revert PendingSendNotFound();
        }
        if (vaultStorage.sendingDisabled) {
            revert SendingDisabled();
        }
        delete vaultStorage.pendingSends[id];
        _payOut(vaultStorage, ps.asset, ps.amount, ps.recipient);
        emit IBittyV1Owner.SendApproved(id, ps.recipient, ps.asset, ps.amount);
    }

    /**
     * @notice Cancel a queued one-off send. The owner may cancel any; a payment manager may cancel
     * only its own. Access control (owner-or-proposer) is enforced by the facade + the check below.
     */
    function cancelSend(VaultStorage storage vaultStorage, uint256 id, bool byOwner)
        external
        onlyInitialized(vaultStorage)
    {
        PendingSend memory ps = vaultStorage.pendingSends[id];
        if (ps.proposer == address(0)) {
            revert PendingSendNotFound();
        }
        if (!byOwner && ps.proposer != msg.sender) {
            revert NotProposalOwner();
        }
        delete vaultStorage.pendingSends[id];
        emit IBittyV1PaymentManager.SendCancelled(id);
    }

    function addScheduledPayment(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment memory scheduledPayment,
        bool byOwner
    ) external onlyInitialized(vaultStorage) returns (uint256 id) {
        if (scheduledPayment.startTimestamp < block.timestamp) {
            revert ScheduledPaymentStartTimestampInPast();
        }
        _checkScheduledPayment(scheduledPayment);
        id = ++vaultStorage.nextScheduledPaymentId;
        vaultStorage.scheduledPayments[id] = scheduledPayment;
        // msg.sender (the proposing payment manager) survives the delegatecall from the facade.
        if (!byOwner) {
            vaultStorage.scheduledPaymentPendingProposer[id] = msg.sender;
        }
        _armAddressProtection(vaultStorage, scheduledPayment.scheduledPaymentAddress);
        emit IBittyV1PaymentManager.ScheduledPaymentAdded(id, scheduledPayment);
    }

    function updateScheduledPayment(
        VaultStorage storage vaultStorage,
        uint256 id,
        IBittyV1Vault.ScheduledPayment memory scheduledPayment,
        bool byOwner
    ) external onlyInitialized(vaultStorage) {
        IBittyV1Vault.ScheduledPayment memory existing = vaultStorage.scheduledPayments[id];
        if (existing.scheduledPaymentAddress == address(0)) {
            revert ScheduledPaymentNotFound();
        }
        if (existing.isImmutable) {
            revert ScheduledPaymentImmutable();
        }
        if (byOwner) {
            // An owner edit vets the entry, so it approves any pending proposal.
            delete vaultStorage.scheduledPaymentPendingProposer[id];
        } else if (vaultStorage.scheduledPaymentPendingProposer[id] != msg.sender) {
            // A payment manager may only edit its own still-pending proposal, never an approved entry.
            revert NotProposalOwner();
        }
        _checkScheduledPayment(scheduledPayment);
        vaultStorage.scheduledPayments[id] = scheduledPayment;
        _armAddressProtection(vaultStorage, scheduledPayment.scheduledPaymentAddress);
        emit IBittyV1PaymentManager.ScheduledPaymentUpdated(id, scheduledPayment);
    }

    /**
     * @notice Owner approval of a payment-manager-proposed scheduled payment. Access control
     * (owner-only) is enforced by the facade.
     */
    function approveScheduledPayment(VaultStorage storage vaultStorage, uint256 id)
        external
        onlyInitialized(vaultStorage)
    {
        if (vaultStorage.scheduledPayments[id].amount == 0) {
            revert ScheduledPaymentNotFound();
        }
        if (vaultStorage.scheduledPaymentPendingProposer[id] == address(0)) {
            revert NotPendingApproval();
        }
        delete vaultStorage.scheduledPaymentPendingProposer[id];
        emit IBittyV1Owner.ScheduledPaymentApproved(id);
    }

    function _checkScheduledPayment(IBittyV1Vault.ScheduledPayment memory scheduledPayment) internal view {
        if (scheduledPayment.scheduledPaymentAddress == address(0)) {
            revert AddressZero();
        }
        // assetAddress address(0) is the "pay in ETH" sentinel; any other asset must be a contract.
        if (scheduledPayment.assetAddress != address(0) && scheduledPayment.assetAddress.code.length == 0) {
            revert AssetAddressNotContract();
        }
        if (scheduledPayment.amount == 0) {
            revert AmountIsZero();
        }
        if (scheduledPayment.remainingPaymentCount == 0) {
            revert ScheduledPaymentPaymentCountZero();
        }
        if (
            scheduledPayment.remainingPaymentCount > 1
                && scheduledPayment.paymentInterval < SCHEDULED_PAYMENT_MINIMAL_INTERVAL
        ) {
            revert ScheduledPaymentIntervalTooShort();
        }
    }

    function removeScheduledPayment(VaultStorage storage vaultStorage, uint256 id, bool byOwner)
        external
        onlyInitialized(vaultStorage)
    {
        // A payment manager may only cancel its own still-pending proposal; the owner can remove any.
        if (!byOwner && vaultStorage.scheduledPaymentPendingProposer[id] != msg.sender) {
            revert NotProposalOwner();
        }
        delete vaultStorage.scheduledPayments[id];
        delete vaultStorage.scheduledPaymentPendingProposer[id];
        delete vaultStorage.lastReceiveTimestamps[id];
        // Intentionally do NOT clear newAddressProtectionTimestamps[scheduledPaymentAddress]: it is
        // shared by payee address across scheduled payments and whitelisted recipients. Clearing it on
        // removal would let a compromised owner drop a still-protected address's time-lock by adding it
        // under two names/features and removing one. The lock self-clears on the first post-window pay
        // and re-adding an address only ever extends it (max), so leaving it here is always safe.
        emit IBittyV1PaymentManager.ScheduledPaymentRemoved(id);
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
        emit IBittyV1Owner.NewAddressProtectionSet(newAddressProtection);
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
     * @notice Add a whitelisted recipient under a fresh auto-increment id.
     * @dev Access control (owner-only) is enforced by the facade.
     */
    function addWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        address recipient,
        address allowedAsset,
        bool byOwner
    ) external onlyInitialized(vaultStorage) returns (uint256 id) {
        if (recipient == address(0)) {
            revert AddressZero();
        }
        id = ++vaultStorage.nextWhitelistedRecipientId;
        vaultStorage.whitelistedRecipients[id] =
            IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset});
        if (!byOwner) {
            vaultStorage.whitelistedRecipientPendingProposer[id] = msg.sender;
        }
        _armAddressProtection(vaultStorage, recipient);
        emit IBittyV1PaymentManager.WhitelistedRecipientSet(id, recipient, allowedAsset);
    }

    /**
     * @notice Update an existing whitelisted recipient. Reverts if `id` does not exist.
     * @dev Access control (owner-or-payment-manager) is enforced by the facade.
     */
    function updateWhitelistedRecipient(
        VaultStorage storage vaultStorage,
        uint256 id,
        address recipient,
        address allowedAsset,
        bool byOwner
    ) external onlyInitialized(vaultStorage) {
        if (recipient == address(0)) {
            revert AddressZero();
        }
        if (vaultStorage.whitelistedRecipients[id].recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        if (byOwner) {
            delete vaultStorage.whitelistedRecipientPendingProposer[id];
        } else if (vaultStorage.whitelistedRecipientPendingProposer[id] != msg.sender) {
            revert NotProposalOwner();
        }
        vaultStorage.whitelistedRecipients[id] =
            IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset});
        _armAddressProtection(vaultStorage, recipient);
        emit IBittyV1PaymentManager.WhitelistedRecipientSet(id, recipient, allowedAsset);
    }

    /**
     * @notice Owner approval of a payment-manager-proposed whitelisted recipient. Access control
     * (owner-only) is enforced by the facade.
     */
    function approveWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id)
        external
        onlyInitialized(vaultStorage)
    {
        if (vaultStorage.whitelistedRecipients[id].recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        if (vaultStorage.whitelistedRecipientPendingProposer[id] == address(0)) {
            revert NotPendingApproval();
        }
        delete vaultStorage.whitelistedRecipientPendingProposer[id];
        emit IBittyV1Owner.WhitelistedRecipientApproved(id);
    }

    /**
     * @notice Remove a whitelisted recipient. Reverts if `id` does not exist.
     * @dev Access control (owner-or-pending-proposer) is enforced by the facade + the check below.
     */
    function removeWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, bool byOwner)
        external
        onlyInitialized(vaultStorage)
    {
        address recipient = vaultStorage.whitelistedRecipients[id].recipient;
        if (recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        if (!byOwner && vaultStorage.whitelistedRecipientPendingProposer[id] != msg.sender) {
            revert NotProposalOwner();
        }
        delete vaultStorage.whitelistedRecipients[id];
        delete vaultStorage.whitelistedRecipientPendingProposer[id];
        // See removeScheduledPayment: the address-keyed protection deadline is shared, so clearing it
        // on removal is exploitable. Leave it — it self-clears on the first post-window pay.
        emit IBittyV1PaymentManager.WhitelistedRecipientRemoved(id);
    }

    /**
     * @notice Pay a whitelisted recipient a discretionary amount from the vault's balance.
     * @dev Access control (owner-only) is enforced by the facade. The asset must match the entry's
     * allowedAsset unless that is address(0) (any asset). Not rate-limited — recipients are vetted
     * by the owner at set time — but a newly added recipient is time-locked by newAddressProtection
     * until its window elapses. Paid from the vault's idle balance.
     */
    function sendToWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id, address asset, uint256 amount)
        external
        onlyInitialized(vaultStorage)
    {
        if (amount == 0) {
            revert AmountIsZero();
        }
        IBittyV1Vault.WhitelistedRecipient memory entry = vaultStorage.whitelistedRecipients[id];
        if (entry.recipient == address(0)) {
            revert WhitelistedRecipientNotFound();
        }
        if (vaultStorage.whitelistedRecipientPendingProposer[id] != address(0)) {
            revert PaymentNotApproved();
        }
        if (entry.allowedAsset != address(0) && asset != entry.allowedAsset) {
            revert WhitelistedRecipientAssetNotAllowed();
        }
        _clearAddressProtection(vaultStorage, entry.recipient);
        _payOut(vaultStorage, asset, amount, entry.recipient);
        emit IBittyV1Owner.WhitelistedRecipientPaid(id, entry.recipient, asset, amount);
    }

    function getWhitelistedRecipient(VaultStorage storage vaultStorage, uint256 id)
        external
        view
        returns (address recipient, address allowedAsset)
    {
        IBittyV1Vault.WhitelistedRecipient memory entry = vaultStorage.whitelistedRecipients[id];
        return (entry.recipient, entry.allowedAsset);
    }

    function payScheduled(VaultStorage storage vaultStorage, uint256 id) external onlyInitialized(vaultStorage) {
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[id];
        if (scheduledPayment.trigger != address(0) && msg.sender != scheduledPayment.trigger) {
            revert ScheduledPaymentTriggerError();
        }
        _payScheduled(vaultStorage, scheduledPayment, id, scheduledPayment.amount);
    }

    function payScheduledAmount(VaultStorage storage vaultStorage, uint256 id, uint256 amount)
        external
        onlyInitialized(vaultStorage)
    {
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[id];
        if (scheduledPayment.amount < amount) {
            revert PayMoreThanScheduledPaymentAmount();
        }
        if (scheduledPayment.trigger == address(0)) {
            revert PayScheduledPaymentAmountTriggerEmpty();
        }
        if (msg.sender != scheduledPayment.trigger) {
            revert ScheduledPaymentTriggerError();
        }
        _payScheduled(vaultStorage, scheduledPayment, id, amount);
    }

    function _payScheduled(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment storage scheduledPayment,
        uint256 id,
        uint256 payAmount
    ) internal {
        _accrueScheduledPayment(vaultStorage, scheduledPayment, id);
        uint256 paidAmount = _transferMoney(
            vaultStorage,
            scheduledPayment.assetAddress,
            payAmount,
            scheduledPayment.scheduledPaymentAddress,
            scheduledPayment.payWithInsufficientBalance
        );
        emit IBittyV1Vault.ScheduledPaymentPaid(
            id,
            scheduledPayment.scheduledPaymentAddress,
            scheduledPayment.assetAddress,
            paidAmount,
            scheduledPayment.remainingPaymentCount
        );
    }

    /**
     * @dev Runs every eligibility check for a scheduled scheduledPayment payment and applies its
     * state effects (advance the interval clock, clear the new-scheduledPayment time-lock, and
     * consume one payment) — but performs no token transfer. Shared by the normal
     * pay-from-vault-balance path and the on-behalf pay-from-yield path so both honour
     * identical rules and checks-effects-interactions ordering.
     */
    function _accrueScheduledPayment(
        VaultStorage storage vaultStorage,
        IBittyV1Vault.ScheduledPayment storage scheduledPayment,
        uint256 id
    ) internal {
        if (scheduledPayment.amount == 0) {
            revert ScheduledPaymentNotFound();
        }
        if (vaultStorage.scheduledPaymentPendingProposer[id] != address(0)) {
            revert PaymentNotApproved();
        }
        if (scheduledPayment.remainingPaymentCount == 0) {
            revert ScheduledPaymentPaymentCountZero();
        }
        if (scheduledPayment.startTimestamp > block.timestamp) {
            revert ScheduledPaymentNotStartYet();
        }
        if (
            scheduledPayment.paymentInterval != 0 && vaultStorage.lastReceiveTimestamps[id] > 0
                && block.timestamp - vaultStorage.lastReceiveTimestamps[id] < scheduledPayment.paymentInterval
        ) {
            revert ScheduledPaymentInInterval();
        }
        _clearAddressProtection(vaultStorage, scheduledPayment.scheduledPaymentAddress);
        vaultStorage.lastReceiveTimestamps[id] = block.timestamp;
        // type(uint8).max is the "unlimited" sentinel: an uncapped recurring scheduled payment that never
        // decrements and so never runs out.
        if (scheduledPayment.remainingPaymentCount != type(uint8).max) {
            scheduledPayment.remainingPaymentCount = scheduledPayment.remainingPaymentCount - 1;
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
    function accrueScheduledPaymentOnBehalf(VaultStorage storage vaultStorage, uint256 id)
        external
        onlyInitialized(vaultStorage)
        returns (address scheduledPaymentAddress, address assetAddress, uint256 payAmount)
    {
        IBittyV1Vault.ScheduledPayment storage scheduledPayment = vaultStorage.scheduledPayments[id];
        if (scheduledPayment.trigger != address(0) && msg.sender != scheduledPayment.trigger) {
            revert ScheduledPaymentTriggerError();
        }
        payAmount = scheduledPayment.amount;
        _accrueScheduledPayment(vaultStorage, scheduledPayment, id);
        scheduledPaymentAddress = scheduledPayment.scheduledPaymentAddress;
        assetAddress = scheduledPayment.assetAddress;
        emit IBittyV1Vault.ScheduledPaymentPaid(
            id, scheduledPaymentAddress, assetAddress, payAmount, scheduledPayment.remainingPaymentCount
        );
    }

    function _transferMoney(
        VaultStorage storage vaultStorage,
        address erc20Address,
        uint256 amount,
        address scheduledPaymentAddress,
        bool payWithInsufficientBalance
    ) internal returns (uint256 paidAmount) {
        // address(0) asset = pay in ETH; the vault holds it as WETH, so measure the balance in WETH.
        address balanceToken = erc20Address == address(0) ? vaultStorage.weth : erc20Address;
        uint256 balance = IERC20(balanceToken).balanceOf(address(this));
        if (!payWithInsufficientBalance && balance < amount) {
            revert InsufficientBalance();
        }
        paidAmount = balance < amount ? balance : amount;
        _payOut(vaultStorage, erc20Address, paidAmount, scheduledPaymentAddress);
    }

    /**
     * @dev `asset == address(0)` pays native ETH by unwrapping WETH — the only payout that .call's an
     * arbitrary recipient, hence the reentrancy guard.
     */
    function _payOut(VaultStorage storage vaultStorage, address asset, uint256 amount, address to) internal {
        if (amount == 0) {
            return;
        }
        if (asset == address(0)) {
            if (vaultStorage.payingEth) {
                revert ReentrantCall();
            }
            vaultStorage.payingEth = true;
            WETH(payable(vaultStorage.weth)).withdraw(amount);
            (bool ok,) = to.call{value: amount}("");
            if (!ok) {
                revert TransferFailed();
            }
            vaultStorage.payingEth = false;
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
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
