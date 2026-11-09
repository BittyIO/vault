// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    NotInitialized,
    PendingChanges,
    RiskTimelockTooLong,
    RiskTimelockTooShort,
    RiskAllowanceOutOfRange,
    VaultLocked
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {BittyStorage, VaultStorage, RiskConfig, TimelockedValue} from "./BittyStorage.sol";
import {TimelockLib} from "./TimelockLib.sol";
import {
    MAX_RISK_TIMELOCK,
    MIN_RISK_TIMELOCK,
    MAX_SEND_DAILY_ALLOWANCE,
    MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE,
    DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE,
    ALLOWANCE_ZERO
} from "./Constants.sol";
import {LockLib} from "./LockLib.sol";

/**
 * @title RiskLogic
 * @notice The main vault's risk surface, which is three numbers: {IBittyV1Owner.RiskSettings.timelock}
 *         — the one wait in front of everything deferred — `sendDailyAllowance`, the ceiling on
 *         what may leave per day through regular sends, and `marketTradeDailyLossAllowance`, the
 *         ceiling on what market trades may lose against oracle value per day. None of them can be
 *         lifted: each is held between the bounds in {Constants}. An unset timelock reads as the
 *         shortest allowed; what an unset allowance reads as depends on the vault's age (below). Either allowance may be set to 0, which turns regular
 *         sends or market trading off — the tightest it can be, so it lands at once, and turning it
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
 *      Unset is stored as 0 rather than written at initialization. An unset timelock is
 *      {MIN_RISK_TIMELOCK}. An unset allowance means one of two things, by
 *      {VaultStorage.unsetRiskIsDefault}: on a vault created with the flag, the new-vault default
 *      (sends off, {DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE} for trades); on an older vault, the
 *      ceiling, as it always has — which is what lets those vaults upgrade with nothing to
 *      migrate. Every read goes through {effectiveTimelock}, {effectiveSendDailyAllowance} and
 *      {effectiveMarketTradeDailyLossAllowance}; reading the slots directly would see a 0 that means
 *      "the default", not "off". An allowance of 0 is stored as {ALLOWANCE_ZERO} for that reason.
 *
 *      Whether a new allowance loosens is judged against the allowance IN FORCE, not the raw slot:
 *      an unset slot on a new vault means sends are off, and raising it must wait out the timelock
 *      like any other loosening. On an older vault the two judgments agree, since an unset slot
 *      there is the ceiling and no allowance can exceed it.
 *
 *      Split out of {PaymentLogic}; operates on the same ERC-7201 {VaultStorage}.
 */
library RiskLogic {
    uint256 constant UNCHANGED = type(uint256).max;

    function _onlyInitialized(VaultStorage storage vaultStorage) private view {
        if (!vaultStorage.isInitialized) revert NotInitialized();
    }

    /**
     * The timelock in force: what the owner set, or {MIN_RISK_TIMELOCK} while they have set nothing.
     */
    function effectiveTimelock(RiskConfig storage r) internal view returns (uint64) {
        return _orDefault(TimelockLib.effective(r.timelock), MIN_RISK_TIMELOCK);
    }

    /**
     * The send allowance in force, in whole USD: what the owner set, or {MAX_SEND_DAILY_ALLOWANCE}.
     */
    function effectiveSendDailyAllowance(VaultStorage storage $) internal view returns (uint64) {
        return _allowance($.riskConfig.sendDailyAllowance, $.unsetRiskIsDefault ? 0 : MAX_SEND_DAILY_ALLOWANCE);
    }

    /**
     * The market-trade loss allowance in force, in whole USD: what the owner set, or
     * {MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE}.
     */
    function effectiveMarketTradeDailyLossAllowance(VaultStorage storage $) internal view returns (uint64) {
        return _allowance(
            $.riskConfig.marketTradeDailyLossAllowance,
            $.unsetRiskIsDefault ? DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE : MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE
        );
    }

    /**
     * An allowance as stored, read back: unset is `unset`, {ALLOWANCE_ZERO} is 0.
     */
    function _allowance(TimelockedValue storage tv, uint64 unset) private view returns (uint64) {
        uint64 v = TimelockLib.effective(tv);
        return v == ALLOWANCE_ZERO ? 0 : _orDefault(v, unset);
    }

    function _orDefault(uint64 value, uint64 unset) private pure returns (uint64) {
        return value == 0 ? unset : value;
    }

    function riskTimelock() external view returns (uint64) {
        return effectiveTimelock(BittyStorage.vault().riskConfig);
    }

    function updateRisk(IBittyV1Owner.RiskSettings calldata settings) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        _onlyInitialized(vaultStorage);
        RiskConfig storage r = vaultStorage.riskConfig;
        if (LockLib.level() != LockLib.NONE) _requireLockedLowering(vaultStorage, settings);
        uint64 timelock = effectiveTimelock(r);
        if (settings.timelock != UNCHANGED) {
            if (settings.timelock > MAX_RISK_TIMELOCK) revert RiskTimelockTooLong();
            if (settings.timelock < MIN_RISK_TIMELOCK) revert RiskTimelockTooShort();
            TimelockLib.setHigherSafer(r.timelock, settings.timelock, timelock);
        }
        if (settings.sendDailyAllowance != UNCHANGED) {
            _setAllowance(
                r.sendDailyAllowance,
                settings.sendDailyAllowance,
                MAX_SEND_DAILY_ALLOWANCE,
                effectiveSendDailyAllowance(vaultStorage),
                timelock
            );
        }
        if (settings.marketTradeDailyLossAllowance != UNCHANGED) {
            _setAllowance(
                r.marketTradeDailyLossAllowance,
                settings.marketTradeDailyLossAllowance,
                MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE,
                effectiveMarketTradeDailyLossAllowance(vaultStorage),
                timelock
            );
        }
        emit IBittyV1Owner.RiskSettingsUpdated(settings);
    }

    /**
     * @dev Under a lock the one number that still bounds a loss is the market-trade loss allowance, as
     *      the owner's sale into a stablecoin is the one trade a lock leaves open. So it alone may move,
     *      and only down, which applies at once; nothing else may, since a lock admits no change that
     *      would wait out the timelock. At 0 the locked sale is off, and under a forever lock that is
     *      for good: an asset the escape destination cannot take is then left to a limit order.
     */
    function _requireLockedLowering(VaultStorage storage $, IBittyV1Owner.RiskSettings calldata settings) private view {
        if (settings.timelock != UNCHANGED || settings.sendDailyAllowance != UNCHANGED) revert VaultLocked();
        if (settings.marketTradeDailyLossAllowance > effectiveMarketTradeDailyLossAllowance($)) revert VaultLocked();
    }

    /**
     * 0 to `max`; 0 is stored as {ALLOWANCE_ZERO}, since a stored 0 means unset. It loosens when it
     * is above `inForce`, the allowance in force before the change.
     */
    function _setAllowance(TimelockedValue storage tv, uint256 allowance, uint64 max, uint64 inForce, uint64 timelock)
        private
    {
        if (allowance > max) revert RiskAllowanceOutOfRange();
        uint64 next = allowance == 0 ? ALLOWANCE_ZERO : uint64(allowance);
        TimelockLib.setCap(tv, next, allowance > inForce, timelock);
    }

    function pendingChanges() external view returns (PendingChanges memory p) {
        VaultStorage storage $ = BittyStorage.vault();
        RiskConfig storage r = $.riskConfig;
        p.lockLevel = LockLib.level();
        (p.timelock, p.timelockAt) = _waiting(r.timelock);
        (p.sendDailyAllowance, p.sendDailyAllowanceAt) = _waiting(r.sendDailyAllowance);
        if (p.sendDailyAllowance == ALLOWANCE_ZERO) p.sendDailyAllowance = 0;
        (p.marketTradeDailyLossAllowance, p.marketTradeDailyLossAllowanceAt) = _waiting(r.marketTradeDailyLossAllowance);
        if (p.marketTradeDailyLossAllowance == ALLOWANCE_ZERO) p.marketTradeDailyLossAllowance = 0;
        (p.gasBudgetDaily, p.gasBudgetDailyAt) = _waiting($.gasBudgetDaily);
        (p.maxFeePerOp, p.maxFeePerOpAt) = _waiting($.maxFeePerOp);
    }

    function _waiting(TimelockedValue storage tv) private view returns (uint64 value, uint64 vaule1) {
        if (tv.pendingAt == 0 || block.timestamp >= tv.pendingAt) return (0, 0);
        return (tv.pending, tv.pendingAt);
    }

    function riskSettings()
        external
        view
        returns (uint64 timelock, uint64 sendDailyAllowance, uint64 marketTradeDailyLossAllowance)
    {
        VaultStorage storage $ = BittyStorage.vault();
        return
            (effectiveTimelock($.riskConfig), effectiveSendDailyAllowance($), effectiveMarketTradeDailyLossAllowance($));
    }
}
