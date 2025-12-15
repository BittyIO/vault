// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IBeneficiary} from "./interfaces/IBeneficiary.sol";
import {ITrust} from "./interfaces/ITrust.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AssetManager} from "./AssetManager.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {
    AddressZero,
    AlreadyInitialized,
    AutoIrrevocableAfterNoPingNotSet,
    StartDistributionTimestampAlreadySet,
    AmountIsZero,
    AmountPerWithdrawalIsZero,
    minimalWithdrawDurationLessThan1Day,
    BeneficiarySettingsNotSet,
    BeneficiaryWithdrawalInLimitDays,
    InsufficientStablecoinBalance,
    TransferFailed,
    EventNameIsEmpty,
    EventNameDuplicated,
    EventNameNotFound,
    percentageMoreThan10K,
    EventTriggerError,
    TimestampIsZero,
    TimestampNotFound,
    TimestampDuplicated,
    LengthMismatch,
    TimestampIsInTheFuture,
    BaseFeeDurationNotMet,
    RevenueDurationNotMet,
    RevenueIsZero,
    RevenueDurationIsZero,
    RevenuePercentageIsZero,
    OnlyRevocable,
    TrusteeStillAlive
} from "./interfaces/Errors.sol";
import {AssetManager} from "./AssetManager.sol";

abstract contract Trust is ITrust {
    uint256 public constant DEFAULT_TRUSTEE_INVALID_AFTER_NO_PING = 180 days;

    address public grantor;
    address public trustee;
    address public assetManager;
    AssetManager.ManageFee public manageFee;
    address public beneficiary;

    bool public isInitialized;
    bool public isIrrevocable;
    uint256 public autoIrrevocableAfterNoPing;
    uint256 public lastPingTime;
    uint256 public autoIrrevocableStartTime;

    uint256 public trusteeInvalidAfterNoPing;
    uint256 public trusteeLastPingTime;

    IBeneficiary.BeneficiarySettings public beneficiarySettings;
    uint256 public lastWithdrawalTime;
    uint256 public startDistributionTimestamp;
    uint256 public lastBaseFeeTime;
    uint256 public revenue;
    uint256 public lastRevenueTime;

    mapping(bytes32 => IBeneficiary.TriggerEvent) public beneficiaryTriggerEvents;
    mapping(uint256 => IBeneficiary.TimeEvent) public beneficiaryTimeEvents;

    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.UintSet;
    EnumerableSet.Bytes32Set private _triggerEventKeys;
    EnumerableSet.UintSet private _timeEventKeys;

    modifier onlyInitialized() {
        require(isInitialized, "Trust not initialized");
        _;
    }

    modifier onlyGrantor() {
        require(msg.sender == grantor, "Only grantor");
        _;
    }

    modifier onlyTrustee() {
        require(msg.sender == trustee, "Only trustee");
        _;
    }

    modifier onlyTrusteeOrGrantor() {
        if (trustee != address(0)) {
            require(msg.sender == trustee, "Only trustee");
            _;
        } else {
            require(msg.sender == grantor, "Only grantor");
            _;
        }
    }

    modifier onlyAssetManager() {
        require(msg.sender == assetManager, "Only asset manager");
        _;
    }

    modifier onlyRevocable() {
        require(this.revocable(), "Only revocable");
        _;
    }

    modifier onlyIrrevokable() {
        require(!this.revocable(), "Only Irrevocable");
        _;
    }

    modifier onlyBeneficiary() {
        require(msg.sender == beneficiary, "Only beneficiary");
        _;
    }

    function initialize(address grantorAddress) external virtual override {
        if (grantorAddress == address(0)) {
            revert AddressZero();
        }
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        grantor = grantorAddress;
        isInitialized = true;
    }

    function initialize(address grantorAddress, address beneficiaryAddress) external virtual override {
        if (grantorAddress == address(0) || beneficiaryAddress == address(0)) {
            revert AddressZero();
        }
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        grantor = grantorAddress;
        beneficiary = beneficiaryAddress;
        isInitialized = true;
    }

    function initialize(address grantorAddress, address beneficiaryAddress, address trusteeAddress)
        external
        virtual
        override
    {
        if (grantorAddress == address(0) || beneficiaryAddress == address(0) || trusteeAddress == address(0)) {
            revert AddressZero();
        }
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        grantor = grantorAddress;
        beneficiary = beneficiaryAddress;
        trustee = trusteeAddress;
        trusteeInvalidAfterNoPing = DEFAULT_TRUSTEE_INVALID_AFTER_NO_PING;
        trusteeLastPingTime = block.timestamp;
        isInitialized = true;
    }

    function revoke() external virtual override onlyInitialized onlyGrantor onlyRevocable {}

    function setToIrrevocable() external virtual override onlyInitialized onlyGrantor {
        isIrrevocable = true;
    }

    function setStartDistributionTimestamp(uint256 startDistributionTimestamp_)
        external
        virtual
        override
        onlyInitialized
        onlyGrantor
    {
        if (startDistributionTimestamp != 0) {
            revert StartDistributionTimestampAlreadySet();
        }
        startDistributionTimestamp = startDistributionTimestamp_;
    }

    function distributionStarted() external view virtual override returns (bool) {
        return block.timestamp >= startDistributionTimestamp;
    }

    function setAutoIrrevocableAfterNoPing(uint256 pingSeconds) external virtual override onlyInitialized onlyGrantor {
        if (!this.revocable()) {
            revert OnlyRevocable();
        }
        autoIrrevocableAfterNoPing = pingSeconds;
        autoIrrevocableStartTime = block.timestamp;
    }

    function grantorPing() external virtual override onlyInitialized onlyGrantor {
        if (autoIrrevocableAfterNoPing == 0) {
            revert AutoIrrevocableAfterNoPingNotSet();
        }
        lastPingTime = block.timestamp;
    }

    function setTrusteeInvalidAfterNoPing(uint256 pingSeconds) external virtual override onlyInitialized onlyGrantor {
        trusteeInvalidAfterNoPing = pingSeconds;
    }

    function trusteePing() external virtual override onlyInitialized onlyTrustee {
        trusteeLastPingTime = block.timestamp;
    }

    function replaceTrustee(address newTrusteeAddress)
        external
        virtual
        override
        onlyInitialized
        onlyBeneficiary
        onlyIrrevokable
    {
        if (newTrusteeAddress == address(0)) {
            revert AddressZero();
        }
        if (block.timestamp - trusteeLastPingTime <= trusteeInvalidAfterNoPing) {
            revert TrusteeStillAlive();
        }
        trustee = newTrusteeAddress;
    }

    function upgrade(address upgradeToContract) external virtual override onlyInitialized onlyGrantor {
        if (upgradeToContract == address(0)) {
            revert AddressZero();
        }
    }

    function changeGrantorAddress(address grantorAddress)
        external
        virtual
        override
        onlyInitialized
        onlyGrantor
        onlyRevocable
    {
        if (grantorAddress == grantor) {
            return;
        }
        if (grantorAddress == address(0)) {
            revert AddressZero();
        }
        grantor = grantorAddress;
    }

    function setTrustee(address trusteeAddress) external virtual override onlyInitialized onlyGrantor onlyRevocable {
        if (trusteeAddress == address(0)) {
            revert AddressZero();
        }
        trustee = trusteeAddress;
        lastBaseFeeTime = block.timestamp;
        lastRevenueTime = block.timestamp;
        trusteeLastPingTime = block.timestamp;
        trusteeInvalidAfterNoPing = DEFAULT_TRUSTEE_INVALID_AFTER_NO_PING;
    }

    function setAssetManager(address assetManagerAddress) external virtual override onlyInitialized onlyTrustee {
        if (assetManagerAddress == address(0)) {
            revert AddressZero();
        }
        assetManager = assetManagerAddress;
    }

    function setManageFee(AssetManager.ManageFee memory manageFee_)
        external
        virtual
        override
        onlyInitialized
        onlyTrustee
    {
        if (manageFee_.baseFeeAmount == 0 && manageFee_.revenuePercentage == 0) {
            revert AmountIsZero();
        }
        if (manageFee_.revenuePercentage > 0 && manageFee_.revenueDuration == 0) {
            revert RevenueDurationIsZero();
        }
        if (manageFee_.revenuePercentage == 0 && manageFee_.revenueDuration > 0) {
            revert RevenuePercentageIsZero();
        }
        manageFee = manageFee_;
    }

    function setBeneficiary(address beneficiaryAddress)
        external
        virtual
        override
        onlyInitialized
        onlyGrantor
        onlyRevocable
    {
        if (beneficiaryAddress == beneficiary) {
            return;
        }
        if (beneficiaryAddress == address(0)) {
            revert AddressZero();
        }
        beneficiary = beneficiaryAddress;
    }

    function setBeneficiarySettings(IBeneficiary.BeneficiarySettings memory beneficiarySettings_)
        external
        virtual
        override
        onlyInitialized
        onlyGrantor
        onlyRevocable
    {
        if (beneficiarySettings_.amountPerWithdrawal == 0) {
            revert AmountPerWithdrawalIsZero();
        }
        if (beneficiarySettings_.minimalWithdrawDuration < 1 days) {
            revert minimalWithdrawDurationLessThan1Day();
        }
        beneficiarySettings = beneficiarySettings_;
    }

    function changeBeneficiaryAddress(address newBeneficiaryAddress)
        external
        virtual
        override
        onlyInitialized
        onlyBeneficiary
    {
        if (newBeneficiaryAddress == address(0)) {
            revert AddressZero();
        }
        beneficiary = newBeneficiaryAddress;
    }

    function changeTrusteeAddress(address newTrusteeAddress) external virtual override onlyInitialized onlyTrustee {
        if (newTrusteeAddress == address(0)) {
            revert AddressZero();
        }
        trustee = newTrusteeAddress;
    }

    function addTriggerEvents(string[] memory eventNames, IBeneficiary.TriggerEvent[] memory triggerEvents)
        external
        virtual
        override
        onlyInitialized
        onlyGrantor
        onlyRevocable
    {
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
            if (beneficiaryTriggerEvents[eventKey].amount > 0) {
                revert EventNameDuplicated();
            }
            if (triggerEvent.isPercentage && triggerEvent.amount > 10000) {
                revert percentageMoreThan10K();
            }
            beneficiaryTriggerEvents[eventKey].triggerAddress = triggerEvent.triggerAddress;
            beneficiaryTriggerEvents[eventKey].amount = triggerEvent.amount;
            beneficiaryTriggerEvents[eventKey].isPercentage = triggerEvent.isPercentage;
            _triggerEventKeys.add(eventKey);
        }
    }

    function removeTriggerEvents(string[] memory eventNames)
        external
        virtual
        override
        onlyInitialized
        onlyGrantor
        onlyRevocable
    {
        for (uint256 i = 0; i < eventNames.length; i++) {
            if (keccak256(bytes(eventNames[i])) == keccak256(bytes(""))) {
                revert EventNameIsEmpty();
            }
            bytes32 eventKey = keccak256(bytes(eventNames[i]));
            if (beneficiaryTriggerEvents[eventKey].amount == 0) {
                revert EventNameNotFound();
            }
            delete beneficiaryTriggerEvents[eventKey];
            _triggerEventKeys.remove(eventKey);
        }
    }

    function getMoneyFromEvent(string memory eventName, address stableCoinAddress)
        external
        virtual
        override
        onlyInitialized
    {
        if (keccak256(bytes(eventName)) == keccak256(bytes(""))) {
            revert EventNameIsEmpty();
        }
        bytes32 eventKey = keccak256(bytes(eventName));
        IBeneficiary.TriggerEvent memory triggerEvent = beneficiaryTriggerEvents[eventKey];
        if (triggerEvent.amount == 0) {
            revert EventNameNotFound();
        }
        if (triggerEvent.triggerAddress != msg.sender) {
            revert EventTriggerError();
        }
        if (!triggerEvent.isPercentage) {
            _getMoney(beneficiaryTriggerEvents[eventKey].amount, stableCoinAddress, beneficiary);
        } else {
            _getPercentageMoney(triggerEvent.amount, beneficiary);
        }
        delete beneficiaryTriggerEvents[eventKey];
        _triggerEventKeys.remove(eventKey);
    }

    function addTimeEvents(uint256[] memory timestamps, IBeneficiary.TimeEvent[] memory timeEvents)
        external
        virtual
        override
        onlyInitialized
        onlyGrantor
        onlyRevocable
    {
        if (timestamps.length != timeEvents.length) {
            revert LengthMismatch();
        }
        for (uint256 i = 0; i < timestamps.length; i++) {
            if (timestamps[i] == 0) {
                revert TimestampIsZero();
            }
            TimeEvent memory timeEvent = timeEvents[i];
            if (timeEvent.amount == 0) {
                revert AmountIsZero();
            }
            if (beneficiaryTimeEvents[timestamps[i]].amount > 0) {
                revert TimestampDuplicated();
            }
            beneficiaryTimeEvents[timestamps[i]] = timeEvent;
            _timeEventKeys.add(timestamps[i]);
        }
    }

    function removeTimeEvents(uint256[] memory timestamps)
        external
        virtual
        override
        onlyInitialized
        onlyGrantor
        onlyRevocable
    {
        for (uint256 i = 0; i < timestamps.length; i++) {
            if (timestamps[i] == 0) {
                revert TimestampIsZero();
            }
            if (beneficiaryTimeEvents[timestamps[i]].amount == 0) {
                revert TimestampNotFound();
            }
            delete beneficiaryTimeEvents[timestamps[i]];
            _timeEventKeys.remove(timestamps[i]);
        }
    }

    function getMoneyByTimestamp(uint256 timestamp, address stableCoinAddress)
        external
        virtual
        override
        onlyInitialized
        onlyBeneficiary
    {
        if (timestamp == 0) {
            revert TimestampIsZero();
        }
        if (beneficiaryTimeEvents[timestamp].amount == 0) {
            revert TimestampNotFound();
        }
        if (timestamp > block.timestamp) {
            revert TimestampIsInTheFuture();
        }
        if (!beneficiaryTimeEvents[timestamp].isPercentage) {
            _getMoney(beneficiaryTimeEvents[timestamp].amount, stableCoinAddress, beneficiary);
        } else {
            _getPercentageMoney(beneficiaryTimeEvents[timestamp].amount, beneficiary);
        }
        delete beneficiaryTimeEvents[timestamp];
        _timeEventKeys.remove(timestamp);
    }

    function getMoney(address stableCoinAddress) external virtual override onlyInitialized onlyBeneficiary {
        if (beneficiarySettings.amountPerWithdrawal == 0) {
            revert BeneficiarySettingsNotSet();
        }
        if (
            lastWithdrawalTime > 0 && block.timestamp - lastWithdrawalTime < beneficiarySettings.minimalWithdrawDuration
        ) {
            revert BeneficiaryWithdrawalInLimitDays();
        }
        _getMoney(beneficiarySettings.amountPerWithdrawal, stableCoinAddress, beneficiary);
        lastWithdrawalTime = block.timestamp;
    }

    function _getMoney(uint256 amount, address stableCoinAddress, address to) internal virtual {}

    function _getPercentageMoney(uint256 persentage, address to) internal virtual {}

    function _transferERC20Token(IERC20 token, uint256 percentage, address to) internal {
        if (address(token) == address(0) || percentage == 0) {
            return;
        }
        uint256 amount = token.balanceOf(address(this)) * percentage / 10000;
        if (amount > 0) {
            if (!token.transfer(to, amount)) {
                revert TransferFailed();
            }
        }
    }

    function getBaseFee(address stableCoinAddress) external virtual override onlyInitialized onlyAssetManager {
        if (block.timestamp - lastBaseFeeTime < manageFee.baseFeeDuration) {
            revert BaseFeeDurationNotMet();
        }
        lastBaseFeeTime = block.timestamp;
        if (!manageFee.isBaseFeePercentage) {
            _getMoney(manageFee.baseFeeAmount, stableCoinAddress, assetManager);
        } else {
            _getPercentageMoney(manageFee.baseFeeAmount, assetManager);
        }
    }

    // TODO, when listing higher with buy low, sell to add revenues and get revenue fee from that
    function getRevenueFee(address stableCoinAddress) external virtual override onlyInitialized onlyAssetManager {
        if (block.timestamp - lastRevenueTime < manageFee.revenueDuration) {
            revert RevenueDurationNotMet();
        }
        if (revenue == 0) {
            revert RevenueIsZero();
        }
        _getMoney(revenue * manageFee.revenuePercentage / 10000, stableCoinAddress, assetManager);
        lastRevenueTime = block.timestamp;
        revenue = 0;
    }

    function revocable() external view virtual returns (bool) {
        if (isIrrevocable) {
            return false;
        }
        if (autoIrrevocableAfterNoPing > 0) {
            if (lastPingTime == 0) {
                return block.timestamp - autoIrrevocableStartTime <= autoIrrevocableAfterNoPing;
            }
            return block.timestamp - lastPingTime <= autoIrrevocableAfterNoPing;
        }
        return true;
    }

    function getAllTriggerEventKeys() external view returns (bytes32[] memory) {
        return _triggerEventKeys.values();
    }

    function getAllTimeEventKeys() external view returns (uint256[] memory) {
        return _timeEventKeys.values();
    }
}
