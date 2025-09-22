// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IGrantor} from "./interfaces/IGrantor.sol";
import {ITrustee} from "./interfaces/ITrustee.sol";
import {IProtector} from "./interfaces/IProtector.sol";

contract BittyTrust is IGrantor, ITrustee, IProtector {
    // State variables
    address public grantor;
    address public trustee;
    address public beneficiary;
    address public protector;
    bool public isInitialized;
    bool public isRevoked;
    uint256 public subscribedToTimestamp;

    // Fund management state
    RebalanceLimit public rebalanceLimit;

    // Trust management state
    TrustLimit public trustLimit;
    uint256 public lastWithdrawalTime;

    // Modifiers
    modifier onlyInitialized() {
        require(isInitialized, "Trust not initialized");
        _;
    }

    modifier onlySubscribed() {
        require(block.timestamp < subscribedToTimestamp, "Trust not subscribed");
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

    modifier onlyProtector() {
        require(msg.sender == protector, "Only protector");
        _;
    }

    // IGrantor implementations
    function initialize(address grantorAddress) external override {
        require(!isInitialized, "Already initialized");
        grantor = grantorAddress;
        isInitialized = true;
    }

    function initaialize(address grantorAddress, address beneficiaryAddress) external override {
        require(!isInitialized, "Already initialized");
        grantor = grantorAddress;
        beneficiary = beneficiaryAddress;
        isInitialized = true;
    }

    function initialize(address grantorAddress, address beneficiaryAddress, address trusteeAddress) external override {
        require(!isInitialized, "Already initialized");
        grantor = grantorAddress;
        beneficiary = beneficiaryAddress;
        trustee = trusteeAddress;
        isInitialized = true;
    }

    function initialize(
        address grantorAddress,
        address beneficiaryAddress,
        address trusteeAddress,
        address protectorAddress
    ) external override {
        require(!isInitialized, "Already initialized");
        grantor = grantorAddress;
        beneficiary = beneficiaryAddress;
        trustee = trusteeAddress;
        protector = protectorAddress;
        isInitialized = true;
    }

    function subscribe(uint256 yearCount) external override onlyInitialized {
        require(yearCount > 0, "Invalid year count");
        subscribedToTimestamp = block.timestamp + (yearCount * 365 days);
    }

    function revoke(address moneyWithdrawTo) external override onlyInitialized onlyGrantor {
        require(moneyWithdrawTo != address(0), "Invalid withdraw address");
        // transfer all the money, WBTC, WETH, USDT, USDC to the moneyWithdrawTo address
        // before transfer, make sure the subscribe fee is paid
        isRevoked = true;
    }

    function upgrade(address upgradeToContract) external override onlyInitialized onlyGrantor {
        require(upgradeToContract != address(0), "Invalid upgrade contract");
        // Upgrade implementation, need to transfer all the money, parameters and subscribe info into the upgraded contract
    }

    function setTrustee(address trusteeAddress) external override onlyInitialized onlyGrantor {
        require(trusteeAddress != address(0), "Invalid trustee address");
        trustee = trusteeAddress;
    }

    function setRebalanceRules(ITrustee.RebalanceLimit memory rebalanceLimit_)
        external
        override
        onlyInitialized
        onlyTrustee
    {
        rebalanceLimit = rebalanceLimit_;
    }

    function supply(address assetAddress, uint256 amount)
        external
        override
        onlyInitialized
        onlySubscribed
        onlyTrustee
    {
        require(assetAddress != address(0), "Invalid asset address");
        require(amount > 0, "Invalid amount");
        // Supply implementation
    }

    function withdraw(address assetAddress, uint256 amount)
        external
        override
        onlyInitialized
        onlySubscribed
        onlyTrustee
    {
        require(assetAddress != address(0), "Invalid asset address");
        require(amount > 0, "Invalid amount");
        // Withdraw implementation
    }

    function rebalance(AssetType from, AssetType to, uint256 sellAmount, uint256 buyAmount, uint256 slippage)
        external
        override
        onlyInitialized
        onlySubscribed
        onlyTrustee
    {
        require(sellAmount > 0, "Invalid sell amount");
        require(buyAmount > 0, "Invalid buy amount");
        require(slippage <= 10000, "Invalid slippage");
        // Rebalance implementation
    }

    function buy(
        AssetType buyAssetType,
        address sellAssetAddress,
        uint256 buyAmount,
        uint256 sellAmount,
        uint256 slippage
    ) external override onlyInitialized onlySubscribed onlyTrustee {
        require(sellAssetAddress != address(0), "Invalid sell asset address");
        require(buyAmount > 0, "Invalid buy amount");
        require(sellAmount > 0, "Invalid sell amount");
        require(slippage <= 10000, "Invalid slippage");
        // Buy implementation
    }

    // IGrantor implementations
    function setBeneficiary(address beneficiaryAddress) external override onlyInitialized onlyGrantor {
        require(beneficiaryAddress != address(0), "Invalid beneficiary address");
        beneficiary = beneficiaryAddress;
    }

    function sendBeneficiary() external override onlyInitialized onlySubscribed onlyGrantor {
        require(beneficiary != address(0), "Beneficiary not set");
        require(
            block.timestamp >= lastWithdrawalTime + (trustLimit.minimalDaysBetweenWithdrawals * 1 days),
            "Too soon for withdrawal"
        );
        uint256 amount = address(this).balance;
        require(amount <= trustLimit.maxWithdrawalAmount, "Exceeds max withdrawal amount");
        lastWithdrawalTime = block.timestamp;
        payable(beneficiary).transfer(amount);
    }

    function setTrustRules(IGrantor.TrustLimit memory trustLimit_) external override onlyInitialized onlyGrantor {
        trustLimit = trustLimit_;
    }

    function setProtector(address protectorAddress) external override onlyInitialized onlyGrantor {
        require(protectorAddress != address(0), "Invalid protector address");
        protector = protectorAddress;
    }

    function pauseFundManagement() external override onlyInitialized onlyProtector {
        // Implementation would pause fund management operations
        // For now, just emit an event or set a state variable
    }

    function resumeFundManagement() external override onlyInitialized onlyProtector {
        // Implementation would resume fund management operations
        // For now, just emit an event or set a state variable
    }

    function replaceTrustee(address newTrusteeAddress) external override onlyInitialized onlyProtector {
        require(newTrusteeAddress != address(0), "Invalid trustee address");
        trustee = newTrusteeAddress;
    }
}
