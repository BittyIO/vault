// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {NotInitialized, PaymentProtectionTooLong} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {BittyStorage, VaultStorage, RiskConfig} from "./BittyStorage.sol";
import {TimelockLib} from "./TimelockLib.sol";
import {MAX_DURATION} from "./Constants.sol";

/**
 * @title RiskLogic
 * @notice The main vault's payment-risk config: new-payment protection window, max send value/interval,
 *         and the change timelock itself. A sentinel partial-update lets the owner touch one field
 *         without restating the rest; tightening applies immediately, loosening waits out the timelock.
 *         Split out of {PaymentLogic}; operates on the same ERC-7201 {VaultStorage}.
 */
library RiskLogic {
    uint256 constant UNCHANGED = type(uint256).max;

    function _onlyInitialized(VaultStorage storage vaultStorage) private view {
        if (!vaultStorage.isInitialized) revert NotInitialized();
    }

    function effectiveChangeTimelock() external view returns (uint64) {
        return TimelockLib.effective(BittyStorage.vault().riskConfig.changeTimelock);
    }

    function updatePaymentRisk(IBittyV1Owner.PaymentRisk calldata paymentRisk) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        _onlyInitialized(vaultStorage);
        uint64 timelock = TimelockLib.effective(vaultStorage.riskConfig.changeTimelock);
        if (paymentRisk.newPaymentProtection != UNCHANGED) {
            if (paymentRisk.newPaymentProtection > MAX_DURATION) revert PaymentProtectionTooLong();
            TimelockLib.setHigherSafer(
                vaultStorage.riskConfig.newPaymentProtection, paymentRisk.newPaymentProtection, timelock
            );
        }
        if (paymentRisk.maxSendValue != UNCHANGED) {
            TimelockLib.setCap(vaultStorage.riskConfig.maxSendValue, paymentRisk.maxSendValue, timelock);
        }
        if (paymentRisk.maxSendInterval != UNCHANGED) {
            TimelockLib.setHigherSafer(vaultStorage.riskConfig.maxSendInterval, paymentRisk.maxSendInterval, timelock);
        }
        if (paymentRisk.changeTimelock != UNCHANGED) {
            TimelockLib.setHigherSafer(vaultStorage.riskConfig.changeTimelock, paymentRisk.changeTimelock, timelock);
        }
        emit IBittyV1Owner.PaymentRiskUpdated(paymentRisk);
    }

    function getRiskConfig()
        external
        view
        returns (uint64 newPaymentProtection, uint64 maxSendValue, uint64 changeTimelock, uint64 maxSendInterval)
    {
        RiskConfig storage r = BittyStorage.vault().riskConfig;
        return (
            TimelockLib.effective(r.newPaymentProtection),
            TimelockLib.effective(r.maxSendValue),
            TimelockLib.effective(r.changeTimelock),
            TimelockLib.effective(r.maxSendInterval)
        );
    }
}
