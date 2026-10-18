// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    NotInitialized,
    PendingChanges,
    RiskTimelockTooLong,
    RiskTimelockTooShort,
    RiskAllowanceOutOfRange
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {BittyStorage, VaultStorage, RiskConfig, TimelockedValue} from "./BittyStorage.sol";
import {TimelockLib} from "./TimelockLib.sol";
import {
    MAX_RISK_TIMELOCK,
    MIN_RISK_TIMELOCK,
    MAX_SEND_DAILY_ALLOWANCE,
    MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE
} from "./Constants.sol";
import {LockLib} from "./LockLib.sol";

/**
 * @title RiskLogic
 * @notice The main vault's risk surface, which is three numbers: {IBittyV1Owner.RiskSettings.timelock}
 *         — the one wait in front of everything deferred — `sendDailyAllowance`, the ceiling on
 *         what may leave per day through regular sends, and `marketTradeDailyLossAllowance`, the
 *         ceiling on what market trades may lose against oracle value per day. None of them can be
 *         turned off: each is held between the bounds in {Constants}, and one the owner has never
 *         set reads as the loosest it may be. A sentinel partial-update lets the owner set one
 *         without restating the others; tightening applies immediately, loosening waits out the
 *         timelock in force when it was asked for.
 *
 * @dev Four numbers used to live here, and the storage held four slots to match. They are three
 *      now — see {IBittyV1Owner.RiskSettings} for which questions collapsed into which, and why the
 *      two allowances are kept apart. The period each allowance runs over is no longer a number at
 *      all: it is a rolling day, as {PaymentLogic} and {MarketTradeLogic} read it.
 *
 *      Unset is stored as 0 rather than written at initialization, so a vault made before these
 *      bounds existed reads the defaults the moment it upgrades, with nothing to migrate. Every read
 *      goes through {effectiveTimelock}, {effectiveSendDailyAllowance} and
 *      {effectiveMarketTradeDailyLossAllowance}; reading the slots directly would see a 0 that means
 *      "the default", not "off". The ratchet in {TimelockLib} needs no change: an unset timelock is the
 *      shortest allowed, and an unset allowance the largest, so nothing the bounds admit is looser.
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
    function effectiveSendDailyAllowance(RiskConfig storage r) internal view returns (uint64) {
        return _orDefault(TimelockLib.effective(r.sendDailyAllowance), MAX_SEND_DAILY_ALLOWANCE);
    }

    /**
     * The market-trade loss allowance in force, in whole USD: what the owner set, or
     * {MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE}.
     */
    function effectiveMarketTradeDailyLossAllowance(RiskConfig storage r) internal view returns (uint64) {
        return _orDefault(TimelockLib.effective(r.marketTradeDailyLossAllowance), MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE);
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
        uint64 timelock = effectiveTimelock(r);
        if (settings.timelock != UNCHANGED) {
            if (settings.timelock > MAX_RISK_TIMELOCK) revert RiskTimelockTooLong();
            if (settings.timelock < MIN_RISK_TIMELOCK) revert RiskTimelockTooShort();
            TimelockLib.setHigherSafer(r.timelock, settings.timelock, timelock);
        }
        if (settings.sendDailyAllowance != UNCHANGED) {
            _requireAllowance(settings.sendDailyAllowance, MAX_SEND_DAILY_ALLOWANCE);
            TimelockLib.setCap(r.sendDailyAllowance, settings.sendDailyAllowance, timelock);
        }
        if (settings.marketTradeDailyLossAllowance != UNCHANGED) {
            _requireAllowance(settings.marketTradeDailyLossAllowance, MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE);
            TimelockLib.setCap(r.marketTradeDailyLossAllowance, settings.marketTradeDailyLossAllowance, timelock);
        }
        emit IBittyV1Owner.RiskSettingsUpdated(settings);
    }

    function _requireAllowance(uint256 allowance, uint64 max) private pure {
        if (allowance == 0 || allowance > max) revert RiskAllowanceOutOfRange();
    }

    function pendingChanges() external view returns (PendingChanges memory p) {
        VaultStorage storage $ = BittyStorage.vault();
        RiskConfig storage r = $.riskConfig;
        p.lockLevel = LockLib.level();
        (p.timelock, p.timelockAt) = _waiting(r.timelock);
        (p.sendDailyAllowance, p.sendDailyAllowanceAt) = _waiting(r.sendDailyAllowance);
        (p.marketTradeDailyLossAllowance, p.marketTradeDailyLossAllowanceAt) = _waiting(r.marketTradeDailyLossAllowance);
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
        RiskConfig storage r = BittyStorage.vault().riskConfig;
        return (effectiveTimelock(r), effectiveSendDailyAllowance(r), effectiveMarketTradeDailyLossAllowance(r));
    }
}
