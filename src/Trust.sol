// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IGrantor} from "./interfaces/IGrantor.sol";
import {IBeneficiary} from "./interfaces/IBeneficiary.sol";
import {ITrustee} from "./interfaces/ITrustee.sol";
import {ITrust} from "./interfaces/ITrust.sol";
import {IERC20} from "./common/IERC20.sol";

abstract contract Trust is ITrust {
    error AddressZero();
    error AlreadyInitialized();
    error Irrevocable();
    error AutoIrrevocableAfterNoPingNotSet();
    error StartDistributionTimestampAlreadySet();
    error AmountPerWithdrawalIsZero();
    error MinimalDaysBetweenWithdrawalsIsZero();
    error BeneficiarySettingsNotSet();
    error BeneficiaryWithdrawalInLimitDays();
    error InsufficientStablecoinBalance();
    error StablecoinTransferFailed();

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

    modifier onlyInitialized() virtual {
        require(isInitialized, "Trust not initialized");
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

    modifier onlyGrantor() {
        require(msg.sender == grantor, "Only grantor");
        _;
    }

    modifier onlyBeneficiary() {
        require(msg.sender == beneficiary, "Only beneficiary");
        _;
    }

    modifier onlyTrustee() virtual {
        require(msg.sender == trustee, "Only trustee");
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

    function revoke(address moneyWithdrawTo) external virtual override onlyInitialized onlyGrantor {
        if (!this.revocable()) {
            revert Irrevocable();
        }
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

    function setTrustee(address trusteeAddress) external virtual override onlyInitialized onlyGrantor {
        if (!this.revocable()) {
            revert Irrevocable();
        }
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

        IERC20 firstWithdrawStableCoin = beneficiarySettings.withdrawUSDTFirst ? this.usdt() : this.usdc();
        IERC20 secondWithdrawStableCoin = beneficiarySettings.withdrawUSDTFirst ? this.usdc() : this.usdt();

        uint256 firstWithdrawStableCoinBalance =
            address(firstWithdrawStableCoin) != address(0) ? firstWithdrawStableCoin.balanceOf(address(this)) : 0;

        if (
            address(firstWithdrawStableCoin) != address(0)
                && firstWithdrawStableCoinBalance >= beneficiarySettings.amountPerWithdrawal
        ) {
            if (!firstWithdrawStableCoin.transfer(beneficiary, beneficiarySettings.amountPerWithdrawal)) {
                revert StablecoinTransferFailed();
            }
            lastWithdrawalTime = block.timestamp;
            return;
        }
        if (
            address(secondWithdrawStableCoin) == address(0)
                || secondWithdrawStableCoin.balanceOf(address(this)) < beneficiarySettings.amountPerWithdrawal
        ) {
            revert InsufficientStablecoinBalance();
        }
        if (!secondWithdrawStableCoin.transfer(beneficiary, beneficiarySettings.amountPerWithdrawal)) {
            revert StablecoinTransferFailed();
        }
        lastWithdrawalTime = block.timestamp;
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
