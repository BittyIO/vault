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
import {RiskLogic} from "./RiskLogic.sol";
import {NO_LIMIT} from "./Constants.sol";
import {LockLib} from "./LockLib.sol";

/**
 * @title PaymentLogic
 * @notice The main vault's core payments: initialization and the owner's own sends, metered by the
 *         send daily allowance. Whitelisted-recipient payouts live in {WhitelistLogic}, the gas budget in
 *         {TokenAsGasLogic}, and the risk config in {RiskLogic}; shared payout/protection primitives
 *         come from {PaymentCore}.
 * @dev Internal, so it compiles into the vault rather than being linked: a send is the commonest call a
 *      vault takes, and reaching a separate library costs it a cold account access every time. The
 *      other logic libraries stay external because the vault could not hold them all.
 */
library PaymentLogic {
    /**
     * @dev A new vault starts open: no timelock, and no limit on regular sends or on what trades
     *      and bridges may lose, which are then not priced at all. The owner protects it by setting
     *      numbers: each one is a tightening from open, so it applies at once.
     *
     *      Nothing is written but the flags: {VaultStorage.unsetIsOpen} makes an unset setting read
     *      as open, and rides in this slot, which is written here anyway. A vault created before
     *      1.1.1 has it false and keeps what its unset settings meant: a day's timelock, and, by
     *      {VaultStorage.unsetRiskIsDefault}, sends off and {DEFAULT_DAILY_LOSS_ALLOWANCE} from
     *      1.0.10, the ceiling before that.
     */
    function initialize(address gasWrapped, bool restrictToOwnAllowList) internal {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        if (vaultStorage.isInitialized) revert AlreadyInitialized();
        vaultStorage.isInitialized = true;
        vaultStorage.unsetRiskIsDefault = true;
        vaultStorage.unsetIsOpen = true;
        vaultStorage.gasWrapped = gasWrapped;
        vaultStorage.ownAllowListActive = restrictToOwnAllowList;
    }

    function send(address recipient, address asset, uint256 amount) internal {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        if (recipient == address(0)) revert AddressZero();
        uint64 cap = _cap(vaultStorage);
        if (cap == NO_LIMIT) {
            if (amount == 0) revert AmountIsZero();
        } else {
            uint256 value = _stableValue(asset, amount);
            if (value > uint256(cap) * 1e18) revert PaymentExceedsRiskCap();
            _checkOwnerSendWindow(vaultStorage, value, cap);
        }
        PaymentCore.payOut(vaultStorage, asset, amount, recipient);
    }

    function batchSend(address recipient, address[] memory assets, uint256[] memory amounts) internal {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        PaymentCore.onlyInitialized(vaultStorage);
        uint256 length = assets.length;
        if (length == 0) revert EmptyArray();
        if (amounts.length != length) revert ArrayLengthMismatch();
        if (recipient == address(0)) revert AddressZero();
        uint64 cap = _cap(vaultStorage);
        if (cap == NO_LIMIT) {
            for (uint256 i = 0; i < length; i++) {
                if (amounts[i] == 0) revert AmountIsZero();
            }
        } else {
            uint256 total;
            for (uint256 i = 0; i < length; i++) {
                total += _stableValue(assets[i], amounts[i]);
                if (total > uint256(cap) * 1e18) revert PaymentExceedsRiskCap();
            }
            _checkOwnerSendWindow(vaultStorage, total, cap);
        }
        for (uint256 i = 0; i < length; i++) {
            PaymentCore.payOut(vaultStorage, assets[i], amounts[i], recipient);
        }
    }

    /**
     * @notice Meters a bridge to someone else's address against the send allowance, as a send of
     *         `amount` of `asset` would be. See {IBittyV1DeFi-bridgeTo}.
     * @dev Unlike a send under {NO_LIMIT}, the asset must be a stablecoin even when nothing is
     *      metered: a bridge out is only ever a stablecoin.
     */
    function meterBridgeOut(address asset, uint256 amount) internal {
        if (!PaymentCore.stableCoinAllowed(asset)) revert PaymentNotStableCoin();
        VaultStorage storage vaultStorage = BittyStorage.vault();
        uint64 cap = _cap(vaultStorage);
        if (cap == NO_LIMIT) return;
        uint256 value = _stableValue(asset, amount);
        if (value > uint256(cap) * 1e18) revert PaymentExceedsRiskCap();
        _checkOwnerSendWindow(vaultStorage, value, cap);
    }

    /**
     * Under a cap every regular send is metered, and only a stablecoin can be metered without reading
     * a price. 0 means the owner turned regular sends off: every amount is over it, so every send is
     * refused. {NO_LIMIT} meters nothing: any asset, any amount.
     */
    function _cap(VaultStorage storage vaultStorage) private view returns (uint64) {
        return RiskLogic.effectiveSendDailyAllowance(vaultStorage);
    }

    /**
     * What one leg is worth in 18-decimal dollars, rounded up so the allowance is never undercounted.
     */
    function _stableValue(address asset, uint256 amount) private view returns (uint256) {
        if (amount == 0) revert AmountIsZero();
        if (!PaymentCore.stableCoinAllowed(asset)) revert PaymentNotStableCoin();
        return Math.mulDiv(amount, 1e18, 10 ** IERC20Metadata(asset).decimals(), Math.Rounding.Ceil);
    }

    function _checkOwnerSendWindow(VaultStorage storage vaultStorage, uint256 batchStableValue, uint64 cap) private {
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
}
