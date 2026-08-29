// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AlreadyInitialized,
    AddressZero,
    AmountIsZero,
    ArrayLengthMismatch,
    EmptyArray,
    NoRescueTarget,
    NotProposalOwner,
    PendingSendNotFound,
    PaymentExceedsRiskCap,
    PaymentExceedsPeriodLimit,
    PaymentNotStableCoin,
    PayoutOperatorNotFound,
    PayoutOperatorAlreadyRegistered
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {IBittyV1PayoutOperator} from "../interfaces/IBittyV1PayoutOperator.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BittyStorage, VaultStorage, PendingSend} from "./BittyStorage.sol";
import {PaymentCore} from "./PaymentCore.sol";
import {TimelockLib} from "./TimelockLib.sol";

/**
 * @title PaymentLogic
 * @notice The main vault's core payments: initialization, sends (direct + payout-operator proposals),
 *         payout operators, and renounce. Scheduled payments live in {ScheduledPaymentLogic},
 *         whitelisted recipients in {WhitelistLogic}, the gas budget in {GaslessLogic}, and the risk
 *         config in {RiskLogic}; shared payout/protection primitives come from {PaymentCore}.
 */
library PaymentLogic {
    function initialize(address weth) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        if (vaultStorage.isInitialized) revert AlreadyInitialized();
        vaultStorage.isInitialized = true;
        vaultStorage.weth = weth;
    }

    function weth() external view returns (address) {
        return BittyStorage.vault().weth;
    }

    function _processSendBatch(
        VaultStorage storage vaultStorage,
        address[] memory recipients,
        address[] memory assets,
        uint256[] memory amounts,
        bool execute,
        bool enforceOwnerSendWindow
    ) private {
        uint256 length = recipients.length;
        if (length == 0) revert EmptyArray();
        if (assets.length != length || amounts.length != length) revert ArrayLengthMismatch();
        _validateSendBatch(vaultStorage, recipients, assets, amounts, execute, enforceOwnerSendWindow);
        if (!execute) return;
        for (uint256 i = 0; i < length; i++) {
            PaymentCore.payOut(vaultStorage, assets[i], amounts[i], recipients[i]);
        }
    }

    function _validateSendBatch(
        VaultStorage storage vaultStorage,
        address[] memory recipients,
        address[] memory assets,
        uint256[] memory amounts,
        bool execute,
        bool enforceOwnerSendWindow
    ) private {
        uint64 cap = TimelockLib.effective(vaultStorage.riskConfig.maxSendValue);
        bool requireStable = cap != 0;
        uint256 totalStableValue;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert AddressZero();
            if (amounts[i] == 0) revert AmountIsZero();
            if (requireStable) {
                if (!PaymentCore.stableCoinAllowed(assets[i])) revert PaymentNotStableCoin();
                uint256 scale = 10 ** IERC20Metadata(assets[i]).decimals();
                totalStableValue += Math.mulDiv(amounts[i], 1e18, scale, Math.Rounding.Ceil);
                if (cap != 0 && totalStableValue > uint256(cap) * 1e18) revert PaymentExceedsRiskCap();
            }
        }
        if (execute && enforceOwnerSendWindow) {
            _checkOwnerSendWindow(vaultStorage, totalStableValue, cap);
        }
    }

    function _checkOwnerSendWindow(VaultStorage storage vaultStorage, uint256 batchStableValue, uint64 cap) private {
        if (cap == 0) return;
        uint64 window = TimelockLib.effective(vaultStorage.riskConfig.maxSendInterval);
        if (window == 0) return;
        uint64 periodStart = vaultStorage.ownerSendPeriodStart;
        uint256 sent = vaultStorage.ownerSentInPeriod;
        if (periodStart == 0 || block.timestamp >= uint256(periodStart) + window) {
            periodStart = uint64(block.timestamp);
            sent = 0;
        }
        uint256 total = sent + batchStableValue;
        if (total > uint256(cap) * 1e18) revert PaymentExceedsPeriodLimit();
        vaultStorage.ownerSendPeriodStart = periodStart;
        vaultStorage.ownerSentInPeriod = uint128(total);
    }

    function send(address[] memory recipients, address[] memory assets, uint256[] memory amounts) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        _processSendBatch(vaultStorage, recipients, assets, amounts, true, true);
    }

    function proposeSend(address[] memory recipients, address[] memory assets, uint256[] memory amounts, address sender)
        external
        returns (uint256 id)
    {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        _processSendBatch(vaultStorage, recipients, assets, amounts, false, false);
        id = vaultStorage.nextPendingSendId++;
        PendingSend storage ps = vaultStorage.pendingSends[id];
        ps.proposer = sender;
        ps.recipients = recipients;
        ps.assets = assets;
        ps.amounts = amounts;
        emit IBittyV1PayoutOperator.SendProposed(id, sender, recipients, assets, amounts);
    }

    function reviewSends(uint256[] calldata approveIds, uint256[] calldata cancelIds, address sender) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        for (uint256 i; i < approveIds.length; ++i) {
            _approveSend(vaultStorage, approveIds[i]);
        }
        for (uint256 i; i < cancelIds.length; ++i) {
            _cancelSend(vaultStorage, cancelIds[i], true, sender);
        }
        if (approveIds.length > 0) emit IBittyV1Owner.SendsApproved(approveIds);
        if (cancelIds.length > 0) emit IBittyV1PayoutOperator.SendsCancelled(cancelIds);
    }

    function cancelSends(uint256[] calldata ids, bool byOwner, address sender) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        for (uint256 i; i < ids.length; ++i) {
            _cancelSend(vaultStorage, ids[i], byOwner, sender);
        }
        if (ids.length > 0) emit IBittyV1PayoutOperator.SendsCancelled(ids);
    }

    function _approveSend(VaultStorage storage vaultStorage, uint256 id) private {
        PendingSend memory ps = vaultStorage.pendingSends[id];
        if (ps.proposer == address(0)) revert PendingSendNotFound();
        delete vaultStorage.pendingSends[id];
        _processSendBatch(vaultStorage, ps.recipients, ps.assets, ps.amounts, true, false);
    }

    function _cancelSend(VaultStorage storage vaultStorage, uint256 id, bool byOwner, address sender) private {
        PendingSend memory ps = vaultStorage.pendingSends[id];
        if (ps.proposer == address(0)) revert PendingSendNotFound();
        if (!byOwner && ps.proposer != sender) revert NotProposalOwner();
        delete vaultStorage.pendingSends[id];
    }

    function approveSendOne(uint256 id) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        _approveSend(vaultStorage, id);
        emit IBittyV1Owner.SendApproved(id);
    }

    function _validateSendOne(
        VaultStorage storage vaultStorage,
        address recipient,
        address asset,
        uint256 amount,
        bool enforceOwnerSendWindow
    ) private {
        if (recipient == address(0)) revert AddressZero();
        if (amount == 0) revert AmountIsZero();
        uint64 cap = TimelockLib.effective(vaultStorage.riskConfig.maxSendValue);
        uint256 stableValue;
        if (cap != 0) {
            if (!PaymentCore.stableCoinAllowed(asset)) revert PaymentNotStableCoin();
            stableValue = Math.mulDiv(amount, 1e18, 10 ** IERC20Metadata(asset).decimals(), Math.Rounding.Ceil);
            if (stableValue > uint256(cap) * 1e18) revert PaymentExceedsRiskCap();
        }
        if (enforceOwnerSendWindow) _checkOwnerSendWindow(vaultStorage, stableValue, cap);
    }

    function sendOne(address recipient, address asset, uint256 amount) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        _validateSendOne(vaultStorage, recipient, asset, amount, true);
        PaymentCore.payOut(vaultStorage, asset, amount, recipient);
    }

    function proposeSendOne(address recipient, address asset, uint256 amount, address sender)
        external
        returns (uint256 id)
    {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        _validateSendOne(vaultStorage, recipient, asset, amount, false);
        id = vaultStorage.nextPendingSendId++;
        PendingSend storage ps = vaultStorage.pendingSends[id];
        ps.proposer = sender;
        ps.recipients.push(recipient);
        ps.assets.push(asset);
        ps.amounts.push(amount);
        emit IBittyV1PayoutOperator.SendProposed(id, sender, ps.recipients, ps.assets, ps.amounts);
    }

    function cancelSendOne(uint256 id, bool byOwner, address sender) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        _cancelSend(vaultStorage, id, byOwner, sender);
        emit IBittyV1PayoutOperator.SendCancelled(id);
    }

    function updatePayoutOperatorOne(address payoutOperator, bool add) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        if (add) {
            if (payoutOperator == address(0)) revert AddressZero();
            if (vaultStorage.payoutOperators[payoutOperator]) revert PayoutOperatorAlreadyRegistered();
            vaultStorage.payoutOperators[payoutOperator] = true;
        } else {
            if (!vaultStorage.payoutOperators[payoutOperator]) revert PayoutOperatorNotFound();
            vaultStorage.payoutOperators[payoutOperator] = false;
        }
    }

    function isPayoutOperator(address account) external view returns (bool) {
        return BittyStorage.vault().payoutOperators[account];
    }

    function prepareRenounce(uint256 rescueScheduledPaymentId) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        if (!PaymentCore.isLockedImmutable(vaultStorage, rescueScheduledPaymentId)) revert NoRescueTarget();
        vaultStorage.renounced = true;
    }
}
