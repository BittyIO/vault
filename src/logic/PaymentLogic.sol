// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AlreadyInitialized,
    AddressZero,
    AmountIsZero,
    ArrayLengthMismatch,
    EmptyArray,
    PaymentExceedsRiskCap,
    PaymentExceedsPeriodLimit,
    PaymentNotStableCoin
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BittyStorage, VaultStorage} from "./BittyStorage.sol";
import {PaymentCore} from "./PaymentCore.sol";
import {TimelockLib} from "./TimelockLib.sol";
import {LockLib} from "./LockLib.sol";

/**
 * @title PaymentLogic
 * @notice The main vault's core payments: initialization and the owner's own sends, metered by the
 *         send daily allowance. Whitelisted-recipient payouts live in {WhitelistLogic}, the gas budget in
 *         {StableCoinAsGasLogic}, and the risk config in {RiskLogic}; shared payout/protection primitives
 *         come from {PaymentCore}.
 */
library PaymentLogic {
    function initialize(address gasWrapped) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        if (vaultStorage.isInitialized) revert AlreadyInitialized();
        vaultStorage.isInitialized = true;
        vaultStorage.gasWrapped = gasWrapped;
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
        uint64 cap = TimelockLib.effective(vaultStorage.riskConfig.sendDailyAllowance); // regular-send daily allowance
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
        uint64 periodStart = vaultStorage.ownerSendPeriodStart;
        uint256 sent = vaultStorage.ownerSentInPeriod;
        if (periodStart == 0 || block.timestamp >= uint256(periodStart) + 1 days) {
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
}
