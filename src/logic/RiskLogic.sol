// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    NotInitialized,
    PendingChanges,
    RiskTimelockTooLong,
    RiskTimelockTooShort,
    TimelockNeedsLimits,
    RiskAllowanceOutOfRange,
    VaultLocked
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {BittyStorage, VaultStorage, RiskConfig, TimelockedValue} from "./BittyStorage.sol";
import {TimelockLib} from "./TimelockLib.sol";
import {
    MAX_RISK_TIMELOCK,
    MIN_RISK_TIMELOCK,
    MAX_DAILY_ALLOWANCE,
    LEGACY_DAILY_ALLOWANCE,
    DEFAULT_DAILY_LOSS_ALLOWANCE,
    STORED_ZERO,
    NO_LIMIT
} from "./Constants.sol";
import {LockLib} from "./LockLib.sol";

/**
 * @title RiskLogic
 * @notice The main vault's risk surface, which is three numbers: {IBittyV1Owner.RiskSettings.timelock}
 *         — the one wait in front of everything deferred — `sendDailyAllowance`, the ceiling on
 *         what may leave per day through regular sends, and `dailyLossAllowance`, the
 *         ceiling on what market trades and bridges may lose against oracle value per day. None of them can be
 *         lifted: each is held between the bounds in {Constants}. An unset timelock reads as the
 *         shortest allowed; what an unset allowance reads as depends on the vault's age (below). Either allowance may be set to 0, which turns regular
 *         sends, or market trading and bridging, off — the tightest it can be, so it lands at once, and turning it
 *         back on waits out the timelock like any loosening. A sentinel partial-update lets the owner set one
 *         without restating the others; tightening applies immediately, loosening waits out the
 *         timelock in force when it was asked for.
 *
 * @dev Four numbers used to live here, and the storage held four slots to match. They are three
 *      now — see {IBittyV1Owner.RiskSettings} for which questions collapsed into which, and why the
 *      two allowances are kept apart. The period each allowance runs over is no longer a number at
 *      all: it is one day, opened by the first send (or loss) and reset by the first one a day or more
 *      later, as {PaymentLogic} and {MarketTradeLogic} keep it. It is not a rolling 24 hours: up to
 *      twice an allowance can leave within moments across the end of one period and the start of
 *      the next.
 *
 *      Unset is stored as 0 rather than written at initialization. An unset timelock is 0 on a
 *      vault created from 1.1.1 on ({VaultStorage.unsetIsOpen}) and
 *      {MIN_RISK_TIMELOCK} on one created before; a timelock of 0 is stored as
 *      {STORED_ZERO}. An unset allowance means one of two things, by
 *      {VaultStorage.unsetIsOpen} and {VaultStorage.unsetRiskIsDefault}: from 1.1.1, no limit
 *      ({NO_LIMIT}); from 1.0.10, sends off and {DEFAULT_DAILY_LOSS_ALLOWANCE} for trades; before
 *      that, the ceiling, as it always has — which is what lets those vaults upgrade with nothing
 *      to migrate. Every read goes through {effectiveTimelock}, {effectiveSendDailyAllowance} and
 *      {effectiveDailyLossAllowance}; reading the slots directly would see a 0 that means
 *      "the default", not "off". An allowance of 0 is stored as {STORED_ZERO} for that reason.
 *
 *      Whether a new allowance loosens is judged against the allowance IN FORCE, not the raw slot:
 *      an unset slot on a 1.0.10 vault means sends are off, and raising it must wait out the
 *      timelock like any other loosening, while on a 1.1.1 vault it means no limit, so any number
 *      is a tightening.
 *
 *      Split out of {PaymentLogic}; operates on the same ERC-7201 {VaultStorage}.
 */
library RiskLogic {
    uint256 constant UNCHANGED = type(uint256).max;

    function _onlyInitialized(VaultStorage storage vaultStorage) private view {
        if (!vaultStorage.isInitialized) revert NotInitialized();
    }

    /**
     * The timelock in force: what the owner set, or while they have set nothing, 0 on a vault
     * created from 1.1.1 on and {MIN_RISK_TIMELOCK} on one created before.
     */
    function effectiveTimelock(VaultStorage storage $) internal view returns (uint64) {
        return _read(TimelockLib.effective($.riskConfig.timelock), _unsetTimelock($));
    }

    /**
     * The send allowance in force, in whole USD, or {NO_LIMIT}: what the owner set, or while they
     * have set nothing, no limit on a vault created from 1.1.1 on, 0 on one created from 1.0.10 on,
     * and {LEGACY_DAILY_ALLOWANCE} on one created before.
     */
    function effectiveSendDailyAllowance(VaultStorage storage $) internal view returns (uint64) {
        return _read(TimelockLib.effective($.riskConfig.sendDailyAllowance), _unsetSend($));
    }

    /**
     * The daily loss allowance in force, in whole USD: what the owner set, or
     * {LEGACY_DAILY_ALLOWANCE}; no limit while unset on a vault created from 1.1.1 on.
     */
    function effectiveDailyLossAllowance(VaultStorage storage $) internal view returns (uint64) {
        return _read(TimelockLib.effective($.riskConfig.dailyLossAllowance), _unsetLoss($));
    }

    function _unsetTimelock(VaultStorage storage $) private view returns (uint64) {
        return $.unsetIsOpen ? 0 : MIN_RISK_TIMELOCK;
    }

    function _unsetSend(VaultStorage storage $) private view returns (uint64) {
        return $.unsetIsOpen ? NO_LIMIT : $.unsetRiskIsDefault ? 0 : LEGACY_DAILY_ALLOWANCE;
    }

    function _unsetLoss(VaultStorage storage $) private view returns (uint64) {
        return $.unsetIsOpen ? NO_LIMIT : $.unsetRiskIsDefault ? DEFAULT_DAILY_LOSS_ALLOWANCE : LEGACY_DAILY_ALLOWANCE;
    }

    /**
     * A value as stored, read back: 0 is unset, so `unset`; {STORED_ZERO} is 0.
     */
    function _read(uint64 stored, uint64 unset) private pure returns (uint64) {
        if (stored == STORED_ZERO) return 0;
        return stored == 0 ? unset : stored;
    }

    /**
     * Where a value is headed: the change still waiting if there is one, else the value itself.
     */
    function _headedTo(TimelockedValue storage tv) private view returns (uint64) {
        return tv.pendingAt != 0 ? tv.pending : tv.value;
    }

    /**
     * A timelock above 0 is protection, and protection with no ceiling protects nothing: a leaked key
     * would send or trade everything away without needing anything the timelock delays. So wherever
     * the settings are headed, a timelock above 0 comes with a number for both allowances. Judged on
     * where each value is headed, so no waiting change can land the vault in that state either.
     */
    function _requireLimitsUnderTimelock(VaultStorage storage $) private view {
        RiskConfig storage r = $.riskConfig;
        if (_read(_headedTo(r.timelock), _unsetTimelock($)) == 0) return;
        if (
            _read(_headedTo(r.sendDailyAllowance), _unsetSend($)) == NO_LIMIT
                || _read(_headedTo(r.dailyLossAllowance), _unsetLoss($)) == NO_LIMIT
        ) revert TimelockNeedsLimits();
    }

    function riskTimelock() external view returns (uint64) {
        return effectiveTimelock(BittyStorage.vault());
    }

    function updateRisk(IBittyV1Owner.RiskSettings calldata settings) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        _onlyInitialized(vaultStorage);
        RiskConfig storage r = vaultStorage.riskConfig;
        if (LockLib.level() != LockLib.NONE) _requireLockedLowering(vaultStorage, settings);
        uint64 timelock = effectiveTimelock(vaultStorage);
        if (settings.timelock != UNCHANGED) {
            if (settings.timelock > MAX_RISK_TIMELOCK) revert RiskTimelockTooLong();
            if (settings.timelock != 0 && settings.timelock < MIN_RISK_TIMELOCK) revert RiskTimelockTooShort();
            uint64 next = settings.timelock == 0 ? STORED_ZERO : uint64(settings.timelock);
            TimelockLib.setCap(r.timelock, next, settings.timelock < timelock, timelock);
        }
        if (settings.sendDailyAllowance != UNCHANGED) {
            _setAllowance(
                r.sendDailyAllowance,
                settings.sendDailyAllowance,
                MAX_DAILY_ALLOWANCE,
                effectiveSendDailyAllowance(vaultStorage),
                timelock
            );
        }
        if (settings.dailyLossAllowance != UNCHANGED) {
            _setAllowance(
                r.dailyLossAllowance,
                settings.dailyLossAllowance,
                MAX_DAILY_ALLOWANCE,
                effectiveDailyLossAllowance(vaultStorage),
                timelock
            );
        }
        _requireLimitsUnderTimelock(vaultStorage);
        emit IBittyV1Owner.RiskSettingsUpdated(settings);
    }

    /**
     * @dev Under a lock the one number that still bounds a loss is the daily loss allowance, as
     *      the owner's sale into a stablecoin is the one trade a lock leaves open. So it alone may move,
     *      and only down, which applies at once; nothing else may, since a lock admits no change that
     *      would wait out the timelock. At 0 the locked sale is off, and under a forever lock that is
     *      for good: an asset the escape destination cannot take is then left to a limit order.
     */
    function _requireLockedLowering(VaultStorage storage $, IBittyV1Owner.RiskSettings calldata settings) private view {
        if (settings.timelock != UNCHANGED || settings.sendDailyAllowance != UNCHANGED) revert VaultLocked();
        if (settings.dailyLossAllowance > effectiveDailyLossAllowance($)) revert VaultLocked();
    }

    /**
     * 0 to `max`, or {NO_LIMIT}; 0 is stored as {STORED_ZERO}, since a stored 0 means unset. It loosens when it
     * is above `inForce`, the allowance in force before the change.
     */
    function _setAllowance(TimelockedValue storage tv, uint256 allowance, uint64 max, uint64 inForce, uint64 timelock)
        private
    {
        if (allowance > max && allowance != NO_LIMIT) revert RiskAllowanceOutOfRange();
        uint64 next = allowance == 0 ? STORED_ZERO : uint64(allowance);
        TimelockLib.setCap(tv, next, allowance > inForce, timelock);
    }

    function pendingChanges() external view returns (PendingChanges memory p) {
        VaultStorage storage $ = BittyStorage.vault();
        RiskConfig storage r = $.riskConfig;
        p.lockLevel = LockLib.level();
        (p.timelock, p.timelockAt) = _waiting(r.timelock);
        if (p.timelock == STORED_ZERO) p.timelock = 0;
        (p.sendDailyAllowance, p.sendDailyAllowanceAt) = _waiting(r.sendDailyAllowance);
        if (p.sendDailyAllowance == STORED_ZERO) p.sendDailyAllowance = 0;
        (p.dailyLossAllowance, p.dailyLossAllowanceAt) = _waiting(r.dailyLossAllowance);
        if (p.dailyLossAllowance == STORED_ZERO) p.dailyLossAllowance = 0;
        (p.gasBudgetDaily, p.gasBudgetDailyAt) = _waiting($.gasBudgetDaily);
        (, p.bridgeEnableAt) = _waiting(BittyStorage.defi().bridgeDisabled);
    }

    function _waiting(TimelockedValue storage tv) private view returns (uint64 value, uint64 vaule1) {
        if (tv.pendingAt == 0 || block.timestamp >= tv.pendingAt) return (0, 0);
        return (tv.pending, tv.pendingAt);
    }

    function riskSettings()
        external
        view
        returns (uint64 timelock, uint64 sendDailyAllowance, uint64 dailyLossAllowance)
    {
        VaultStorage storage $ = BittyStorage.vault();
        return (effectiveTimelock($), effectiveSendDailyAllowance($), effectiveDailyLossAllowance($));
    }
}
