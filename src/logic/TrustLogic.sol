// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IBeneficiary} from "../interfaces/IBeneficiary.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {
    AddressZero,
    AmountIsZero,
    AmountPerWithdrawalIsZero,
    minimalWithdrawDurationLessThan1Day,
    BeneficiarySettingsNotSet,
    BeneficiaryWithdrawalInLimitDays,
    EventNameIsEmpty,
    EventNameDuplicated,
    EventNameNotFound,
    percentageMoreThan10K,
    EventTriggerError,
    TimestampIsZero,
    TimestampNotFound,
    TimestampDuplicated,
    TimestampIsInTheFuture,
    LengthMismatch,
    StartDistributionTimestampAlreadySet,
    AutoIrrevocableAfterNoPingNotSet,
    NotInitialized,
    AlreadyInitialized
} from "../interfaces/Errors.sol";
import {VaultLogic} from "./VaultLogic.sol";
import {TrustStorage, AssetManagerStorage, VaultStorage} from "./Storages.sol";

library TrustLogic {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    modifier onlyInitialized(TrustStorage storage trustStorage) {
        _onlyInitialized(trustStorage);
        _;
    }

    function _onlyInitialized(TrustStorage storage trustStorage) private view {
        if (!trustStorage.isInitialized) {
            revert NotInitialized();
        }
    }

    modifier onlyNotInitialized(TrustStorage storage trustStorage) {
        _onlyNotInitialized(trustStorage);
        _;
    }

    function _onlyNotInitialized(TrustStorage storage trustStorage) private view {
        if (trustStorage.isInitialized) {
            revert AlreadyInitialized();
        }
    }

    function initialize(TrustStorage storage trustStorage) external onlyNotInitialized(trustStorage) {
        trustStorage.isInitialized = true;
    }

    function _revocable(TrustStorage storage trustStorage) private view returns (bool) {
        if (trustStorage.isIrrevocable) {
            return false;
        }
        if (trustStorage.autoIrrevocableAfterNoPing > 0) {
            if (trustStorage.lastPingTime == 0) {
                return
                    block.timestamp - trustStorage.autoIrrevocableStartTime <= trustStorage.autoIrrevocableAfterNoPing;
            }
            return block.timestamp - trustStorage.lastPingTime <= trustStorage.autoIrrevocableAfterNoPing;
        }
        return true;
    }

    function revoke(TrustStorage storage trustStorage) external onlyInitialized(trustStorage) {}

    function setToIrrevocable(TrustStorage storage trustStorage) external onlyInitialized(trustStorage) {
        trustStorage.isIrrevocable = true;
    }

    function setStartDistributionTimestamp(TrustStorage storage trustStorage, uint256 startDistributionTimestamp_)
        external
        onlyInitialized(trustStorage)
    {
        if (trustStorage.startDistributionTimestamp != 0) {
            revert StartDistributionTimestampAlreadySet();
        }
        trustStorage.startDistributionTimestamp = startDistributionTimestamp_;
    }

    function distributionStarted(TrustStorage storage trustStorage) external view returns (bool) {
        return block.timestamp >= trustStorage.startDistributionTimestamp;
    }

    function setAutoIrrevocableAfterNoPing(TrustStorage storage trustStorage, uint256 pingSeconds)
        external
        onlyInitialized(trustStorage)
    {
        trustStorage.autoIrrevocableAfterNoPing = pingSeconds;
        trustStorage.autoIrrevocableStartTime = block.timestamp;
    }

    function ping(TrustStorage storage trustStorage) external onlyInitialized(trustStorage) {
        if (trustStorage.autoIrrevocableAfterNoPing == 0) {
            revert AutoIrrevocableAfterNoPingNotSet();
        }
        trustStorage.lastPingTime = block.timestamp;
    }

    function upgrade(TrustStorage storage trustStorage, address upgradeToContract)
        external
        view
        onlyInitialized(trustStorage)
    {
        if (upgradeToContract == address(0)) {
            revert AddressZero();
        }
    }

    function setTrustee(TrustStorage storage trustStorage, address trusteeAddress)
        external
        onlyInitialized(trustStorage)
    {
        if (trusteeAddress == address(0)) {
            revert AddressZero();
        }
        trustStorage.trustee = trusteeAddress;
    }

    function setBeneficiary(TrustStorage storage trustStorage, address beneficiaryAddress)
        external
        onlyInitialized(trustStorage)
    {
        if (beneficiaryAddress == trustStorage.beneficiary) {
            return;
        }
        if (beneficiaryAddress == address(0)) {
            revert AddressZero();
        }
        trustStorage.beneficiary = beneficiaryAddress;
    }

    function setBeneficiarySettings(
        TrustStorage storage trustStorage,
        IBeneficiary.BeneficiarySettings memory beneficiarySettings_
    ) external onlyInitialized(trustStorage) {
        if (beneficiarySettings_.amountPerWithdrawal == 0) {
            revert AmountPerWithdrawalIsZero();
        }
        if (beneficiarySettings_.minimalWithdrawDuration < 1 days) {
            revert minimalWithdrawDurationLessThan1Day();
        }
        trustStorage.beneficiarySettings = beneficiarySettings_;
    }

    function changeBeneficiaryAddress(TrustStorage storage trustStorage, address newBeneficiaryAddress)
        external
        onlyInitialized(trustStorage)
    {
        if (newBeneficiaryAddress == address(0)) {
            revert AddressZero();
        }
        trustStorage.beneficiary = newBeneficiaryAddress;
    }

    function changeTrusteeAddress(TrustStorage storage trustStorage, address newTrusteeAddress)
        external
        onlyInitialized(trustStorage)
    {
        if (newTrusteeAddress == address(0)) {
            revert AddressZero();
        }
        trustStorage.trustee = newTrusteeAddress;
    }

    function addTriggerEvents(
        TrustStorage storage trustStorage,
        string[] memory eventNames,
        IBeneficiary.TriggerEvent[] memory triggerEvents
    ) external onlyInitialized(trustStorage) {
        if (eventNames.length != triggerEvents.length) {
            revert LengthMismatch();
        }
        for (uint256 i = 0; i < eventNames.length; i++) {
            IBeneficiary.TriggerEvent memory triggerEvent = triggerEvents[i];
            if (keccak256(bytes(eventNames[i])) == keccak256(bytes(""))) {
                revert EventNameIsEmpty();
            }
            if (triggerEvent.triggerAddress == address(0)) {
                revert AddressZero();
            }
            if (triggerEvent.amount == 0) {
                revert AmountIsZero();
            }
            bytes32 eventKey = keccak256(bytes(eventNames[i]));
            if (trustStorage.beneficiaryTriggerEvents[eventKey].amount > 0) {
                revert EventNameDuplicated();
            }
            if (triggerEvent.isPercentage && triggerEvent.amount > 10000) {
                revert percentageMoreThan10K();
            }
            trustStorage.beneficiaryTriggerEvents[eventKey].triggerAddress = triggerEvent.triggerAddress;
            trustStorage.beneficiaryTriggerEvents[eventKey].amount = triggerEvent.amount;
            trustStorage.beneficiaryTriggerEvents[eventKey].isPercentage = triggerEvent.isPercentage;
            trustStorage.triggerEventKeys.add(eventKey);
        }
    }

    function removeTriggerEvents(TrustStorage storage trustStorage, string[] memory eventNames)
        external
        onlyInitialized(trustStorage)
    {
        for (uint256 i = 0; i < eventNames.length; i++) {
            if (keccak256(bytes(eventNames[i])) == keccak256(bytes(""))) {
                revert EventNameIsEmpty();
            }
            bytes32 eventKey = keccak256(bytes(eventNames[i]));
            if (trustStorage.beneficiaryTriggerEvents[eventKey].amount == 0) {
                revert EventNameNotFound();
            }
            delete trustStorage.beneficiaryTriggerEvents[eventKey];
            trustStorage.triggerEventKeys.remove(eventKey);
        }
    }

    function getMoneyFromEvent(
        TrustStorage storage trustStorage,
        VaultStorage storage vaultStorage,
        AssetManagerStorage storage assetManagerStorage,
        string memory eventName,
        address stableCoinAddress,
        address to
    ) external onlyInitialized(trustStorage) {
        if (keccak256(bytes(eventName)) == keccak256(bytes(""))) {
            revert EventNameIsEmpty();
        }
        bytes32 eventKey = keccak256(bytes(eventName));
        IBeneficiary.TriggerEvent memory triggerEvent = trustStorage.beneficiaryTriggerEvents[eventKey];
        if (triggerEvent.amount == 0) {
            revert EventNameNotFound();
        }
        if (triggerEvent.triggerAddress != msg.sender) {
            revert EventTriggerError();
        }
        if (!triggerEvent.isPercentage) {
            VaultLogic.getMoney(vaultStorage, assetManagerStorage, triggerEvent.amount, stableCoinAddress, to);
        } else {
            VaultLogic.getPercentageMoney(vaultStorage, triggerEvent.amount, to);
        }
        delete trustStorage.beneficiaryTriggerEvents[eventKey];
        trustStorage.triggerEventKeys.remove(eventKey);
    }

    function addTimeEvents(
        TrustStorage storage trustStorage,
        uint256[] memory timestamps,
        IBeneficiary.TimeEvent[] memory timeEvents
    ) external onlyInitialized(trustStorage) {
        if (timestamps.length != timeEvents.length) {
            revert LengthMismatch();
        }
        for (uint256 i = 0; i < timestamps.length; i++) {
            if (timestamps[i] == 0) {
                revert TimestampIsZero();
            }
            IBeneficiary.TimeEvent memory timeEvent = timeEvents[i];
            if (timeEvent.amount == 0) {
                revert AmountIsZero();
            }
            if (trustStorage.beneficiaryTimeEvents[timestamps[i]].amount > 0) {
                revert TimestampDuplicated();
            }
            trustStorage.beneficiaryTimeEvents[timestamps[i]] = timeEvent;
            trustStorage.timeEventKeys.add(timestamps[i]);
        }
    }

    function removeTimeEvents(TrustStorage storage trustStorage, uint256[] memory timestamps)
        external
        onlyInitialized(trustStorage)
    {
        for (uint256 i = 0; i < timestamps.length; i++) {
            if (timestamps[i] == 0) {
                revert TimestampIsZero();
            }
            if (trustStorage.beneficiaryTimeEvents[timestamps[i]].amount == 0) {
                revert TimestampNotFound();
            }
            delete trustStorage.beneficiaryTimeEvents[timestamps[i]];
            trustStorage.timeEventKeys.remove(timestamps[i]);
        }
    }

    function getMoneyByTimestamp(
        TrustStorage storage trustStorage,
        VaultStorage storage vaultStorage,
        AssetManagerStorage storage assetManagerStorage,
        uint256 timestamp,
        address stableCoinAddress
    ) external onlyInitialized(trustStorage) {
        if (timestamp == 0) {
            revert TimestampIsZero();
        }
        if (trustStorage.beneficiaryTimeEvents[timestamp].amount == 0) {
            revert TimestampNotFound();
        }
        if (timestamp > block.timestamp) {
            revert TimestampIsInTheFuture();
        }
        if (!trustStorage.beneficiaryTimeEvents[timestamp].isPercentage) {
            VaultLogic.getMoney(
                vaultStorage,
                assetManagerStorage,
                trustStorage.beneficiaryTimeEvents[timestamp].amount,
                stableCoinAddress,
                trustStorage.beneficiary
            );
        } else {
            VaultLogic.getPercentageMoney(
                vaultStorage, trustStorage.beneficiaryTimeEvents[timestamp].amount, trustStorage.beneficiary
            );
        }
        delete trustStorage.beneficiaryTimeEvents[timestamp];
        trustStorage.timeEventKeys.remove(timestamp);
    }

    function getMoney(
        TrustStorage storage trustStorage,
        VaultStorage storage vaultStorage,
        AssetManagerStorage storage assetManagerStorage,
        address stableCoinAddress
    ) external onlyInitialized(trustStorage) {
        if (trustStorage.beneficiarySettings.amountPerWithdrawal == 0) {
            revert BeneficiarySettingsNotSet();
        }
        if (
            trustStorage.lastWithdrawalTime > 0
                && block.timestamp - trustStorage.lastWithdrawalTime
                    < trustStorage.beneficiarySettings.minimalWithdrawDuration
        ) {
            revert BeneficiaryWithdrawalInLimitDays();
        }
        VaultLogic.getMoney(
            vaultStorage,
            assetManagerStorage,
            trustStorage.beneficiarySettings.amountPerWithdrawal,
            stableCoinAddress,
            trustStorage.beneficiary
        );
        trustStorage.lastWithdrawalTime = block.timestamp;
    }

    function getAllTriggerEventKeys(TrustStorage storage trustStorage)
        external
        view
        onlyInitialized(trustStorage)
        returns (bytes32[] memory)
    {
        return trustStorage.triggerEventKeys.values();
    }

    function getAllTimeEventKeys(TrustStorage storage trustStorage)
        external
        view
        onlyInitialized(trustStorage)
        returns (uint256[] memory)
    {
        return trustStorage.timeEventKeys.values();
    }

    function _transferERC20Token(IERC20 token, uint256 percentage, address to) private {
        if (address(token) == address(0) || percentage == 0) {
            return;
        }
        uint256 amount = token.balanceOf(address(this)) * percentage / 10000;
        if (amount > 0) {
            token.safeTransfer(to, amount);
        }
    }

    function revocable(TrustStorage storage trustStorage) external view returns (bool) {
        return _revocable(trustStorage);
    }
}
