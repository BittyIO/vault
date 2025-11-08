// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IBeneficiary} from "./interfaces/IBeneficiary.sol";
import {ITrust} from "./interfaces/ITrust.sol";
import {IERC20} from "./common/IERC20.sol";

abstract contract Trust is ITrust {
    error AddressZero();
    error AlreadyInitialized();
    error AutoIrrevocableAfterNoPingNotSet();
    error StartDistributionTimestampAlreadySet();
    error AmountPerWithdrawalIsZero();
    error MinimalDaysBetweenWithdrawalsIsZero();
    error BeneficiarySettingsNotSet();
    error BeneficiaryWithdrawalInLimitDays();
    error InsufficientStablecoinBalance();
    error StablecoinTransferFailed();
    error EventNameIsEmpty();
    error EventNameDuplicated();
    error EventNameNotFound();
    error AmountIsZero();
    error EventTriggerError();
    error TimestampIsZero();
    error TimestampNotFound();
    error TimestampDuplicated();
    error LengthMismatch();
    error TimestampIsInTheFuture();

    address public grantor;
    address public trustee;
    address public beneficiary;

    bool public isInitialized;
    bool public isIrrevocable;
    uint256 public autoIrrevocableAfterNoPing;
    uint256 public lastPingTime;
    uint256 public autoIrrevocableStartTime;

    IBeneficiary.BeneficiarySettings public beneficiarySettings;
    uint256 public lastWithdrawalTime;
    uint256 public startDistributionTimestamp;

    mapping(string => IBeneficiary.TriggerEvent) public beneficiaryTriggerEvents;
    mapping(uint256 => uint256) public beneficiaryTimeEvents;

    modifier onlyInitialized() virtual {
        require(isInitialized, "Trust not initialized");
        _;
    }

    modifier onlyGrantor() virtual {
        require(msg.sender == grantor, "Only grantor");
        _;
    }

    modifier onlyTrustee() virtual {
        require(msg.sender == trustee, "Only trustee");
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

    function initaialize(address grantorAddress, address beneficiaryAddress) external virtual override {
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
        isInitialized = true;
    }

    function revoke(address moneyWithdrawTo) external virtual override onlyInitialized onlyGrantor onlyRevocable {
        if (moneyWithdrawTo == address(0)) {
            revert AddressZero();
        }
    }

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
        autoIrrevocableAfterNoPing = pingSeconds;
        autoIrrevocableStartTime = block.timestamp;
    }

    function ping() external virtual override onlyInitialized onlyGrantor {
        if (autoIrrevocableAfterNoPing == 0) {
            revert AutoIrrevocableAfterNoPingNotSet();
        }
        lastPingTime = block.timestamp;
    }

    function upgrade(address upgradeToContract) external virtual override onlyInitialized onlyGrantor {
        if (upgradeToContract == address(0)) {
            revert AddressZero();
        }
    }

    function setGrantor(address grantorAddress) external virtual override onlyInitialized onlyGrantor {
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
    }

    function setBeneficiary(address beneficiaryAddress) external virtual override onlyInitialized onlyGrantor {
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
    {
        if (beneficiarySettings_.amountPerWithdrawal == 0) {
            revert AmountPerWithdrawalIsZero();
        }
        if (beneficiarySettings_.minimalDaysBetweenWithdrawals == 0) {
            revert MinimalDaysBetweenWithdrawalsIsZero();
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
            if (keccak256(bytes(eventNames[i])) == keccak256(bytes(""))) {
                revert EventNameIsEmpty();
            }
            if (triggerEvents[i].triggerAddress == address(0)) {
                revert AddressZero();
            }
            if (triggerEvents[i].amount == 0) {
                revert AmountIsZero();
            }
            if (beneficiaryTriggerEvents[eventNames[i]].amount > 0) {
                revert EventNameDuplicated();
            }
            beneficiaryTriggerEvents[eventNames[i]].triggerAddress = triggerEvents[i].triggerAddress;
            beneficiaryTriggerEvents[eventNames[i]].amount = triggerEvents[i].amount;
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
            if (beneficiaryTriggerEvents[eventNames[i]].amount == 0) {
                revert EventNameNotFound();
            }
            delete beneficiaryTriggerEvents[eventNames[i]];
        }
    }

    function getMoneyFromEvent(string memory eventName) external virtual override onlyInitialized {
        if (keccak256(bytes(eventName)) == keccak256(bytes(""))) {
            revert EventNameIsEmpty();
        }
        if (beneficiaryTriggerEvents[eventName].amount == 0) {
            revert EventNameNotFound();
        }
        if (beneficiaryTriggerEvents[eventName].triggerAddress != msg.sender) {
            revert EventTriggerError();
        }
        _getMoney(beneficiaryTriggerEvents[eventName].amount);
        delete beneficiaryTriggerEvents[eventName];
    }

    function addTimeEvents(uint256[] memory timestamps, uint256[] memory amounts)
        external
        virtual
        override
        onlyInitialized
        onlyGrantor
        onlyRevocable
    {
        if (timestamps.length != amounts.length) {
            revert LengthMismatch();
        }
        for (uint256 i = 0; i < timestamps.length; i++) {
            if (timestamps[i] == 0) {
                revert TimestampIsZero();
            }
            if (amounts[i] == 0) {
                revert AmountIsZero();
            }
            if (beneficiaryTimeEvents[timestamps[i]] > 0) {
                revert TimestampDuplicated();
            }
            beneficiaryTimeEvents[timestamps[i]] = amounts[i];
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
            if (beneficiaryTimeEvents[timestamps[i]] == 0) {
                revert TimestampNotFound();
            }
            delete beneficiaryTimeEvents[timestamps[i]];
        }
    }

    function getMoneyByTimestamp(uint256 timestamp) external virtual override onlyInitialized onlyBeneficiary {
        if (timestamp == 0) {
            revert TimestampIsZero();
        }
        if (beneficiaryTimeEvents[timestamp] == 0) {
            revert TimestampNotFound();
        }
        if (timestamp > block.timestamp) {
            revert TimestampIsInTheFuture();
        }
        _getMoney(beneficiaryTimeEvents[timestamp]);
        delete beneficiaryTimeEvents[timestamp];
    }

    function getMoney() external virtual override onlyInitialized onlyBeneficiary {
        if (beneficiarySettings.amountPerWithdrawal == 0) {
            revert BeneficiarySettingsNotSet();
        }
        if (
            lastWithdrawalTime > 0
                && block.timestamp - lastWithdrawalTime < beneficiarySettings.minimalDaysBetweenWithdrawals * 1 days
        ) {
            revert BeneficiaryWithdrawalInLimitDays();
        }
        _getMoney(beneficiarySettings.amountPerWithdrawal);
        lastWithdrawalTime = block.timestamp;
    }

    function _getMoney(uint256 amount) internal {
        IERC20 firstWithdrawStableCoin = beneficiarySettings.withdrawUSDTFirst ? this.usdt() : this.usdc();
        IERC20 secondWithdrawStableCoin = beneficiarySettings.withdrawUSDTFirst ? this.usdc() : this.usdt();

        uint256 firstWithdrawStableCoinBalance =
            address(firstWithdrawStableCoin) != address(0) ? firstWithdrawStableCoin.balanceOf(address(this)) : 0;

        if (address(firstWithdrawStableCoin) != address(0) && firstWithdrawStableCoinBalance >= amount) {
            if (!firstWithdrawStableCoin.transfer(beneficiary, amount)) {
                revert StablecoinTransferFailed();
            }
            return;
        }
        if (
            address(secondWithdrawStableCoin) == address(0)
                || secondWithdrawStableCoin.balanceOf(address(this)) < amount
        ) {
            revert InsufficientStablecoinBalance();
        }
        if (!secondWithdrawStableCoin.transfer(beneficiary, amount)) {
            revert StablecoinTransferFailed();
        }
    }

    function usdt() external view virtual returns (IERC20);
    function usdc() external view virtual returns (IERC20);

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
}
