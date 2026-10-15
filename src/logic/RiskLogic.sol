// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {NotInitialized, PendingChanges, RiskTimelockTooLong} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {BittyStorage, VaultStorage, RiskConfig, TimelockedValue} from "./BittyStorage.sol";
import {TimelockLib} from "./TimelockLib.sol";
import {MAX_RISK_TIMELOCK} from "./Constants.sol";
import {LockLib} from "./LockLib.sol";

/**
 * @title RiskLogic
 * @notice The main vault's risk surface, which is two numbers: {IBittyV1Owner.RiskSettings.timelock}
 *         — the one wait in front of everything deferred — and `sendDailyAllowance`, the ceiling on
 *         what may leave per day through regular sends. A sentinel partial-update lets the
 *         owner set one without restating the other; tightening applies immediately, loosening waits
 *         out the timelock in force when it was asked for.
 *
 * @dev Four numbers used to live here, and the storage held four slots to match. Both are two now —
 *      see {RiskConfig} for which questions collapsed into which. The period the allowance runs over
 *      is no longer a number at all: it is a day, as {PaymentLogic} reads it.
 *
 *      Split out of {PaymentLogic}; operates on the same ERC-7201 {VaultStorage}.
 */
library RiskLogic {
    uint256 constant UNCHANGED = type(uint256).max;

    function _onlyInitialized(VaultStorage storage vaultStorage) private view {
        if (!vaultStorage.isInitialized) revert NotInitialized();
    }

    function riskTimelock() external view returns (uint64) {
        return TimelockLib.effective(BittyStorage.vault().riskConfig.timelock);
    }

    function updateRisk(IBittyV1Owner.RiskSettings calldata settings) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        _onlyInitialized(vaultStorage);
        RiskConfig storage r = vaultStorage.riskConfig;
        uint64 timelock = TimelockLib.effective(r.timelock);
        if (settings.timelock != UNCHANGED) {
            if (settings.timelock > MAX_RISK_TIMELOCK) revert RiskTimelockTooLong();
            TimelockLib.setHigherSafer(r.timelock, settings.timelock, timelock);
        }
        if (settings.sendDailyAllowance != UNCHANGED) {
            TimelockLib.setCap(r.sendDailyAllowance, settings.sendDailyAllowance, timelock);
        }
        emit IBittyV1Owner.RiskSettingsUpdated(settings);
    }

    function pendingChanges() external view returns (PendingChanges memory p) {
        VaultStorage storage $ = BittyStorage.vault();
        RiskConfig storage r = $.riskConfig;
        p.lockLevel = LockLib.level();
        (p.timelock, p.timelockAt) = _waiting(r.timelock);
        (p.sendDailyAllowance, p.sendDailyAllowanceAt) = _waiting(r.sendDailyAllowance);
        (p.gasBudgetDaily, p.gasBudgetDailyAt) = _waiting($.gasBudgetDaily);
        (p.maxFeePerOp, p.maxFeePerOpAt) = _waiting($.maxFeePerOp);
    }

    function _waiting(TimelockedValue storage tv) private view returns (uint64 value, uint64 vaule1) {
        if (tv.pendingAt == 0 || block.timestamp >= tv.pendingAt) return (0, 0);
        return (tv.pending, tv.pendingAt);
    }

    function riskSettings() external view returns (uint64 timelock, uint64 sendDailyAllowance) {
        RiskConfig storage r = BittyStorage.vault().riskConfig;
        return (TimelockLib.effective(r.timelock), TimelockLib.effective(r.sendDailyAllowance));
    }
}
