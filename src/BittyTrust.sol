// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {ITrust} from "./interfaces/ITrust.sol";
import {ITrustee} from "./interfaces/ITrustee.sol";
import {IGrantor} from "./interfaces/IGrantor.sol";
import {IProtector} from "./interfaces/IProtector.sol";

contract BittyTrust is ITrust {
    error AddressZero();
    error AlreadyInitialized();
    error Irrevocable();
    error AutoIrrevocableAfterNoPingNotSet();

    // State variables
    address public grantor;
    address public trustee;
    address public beneficiary;
    address public protector;
    bool public isInitialized;
    bool public isIrrevocable;
    uint256 public autoIrrevocableAfterNoPing;
    uint256 public lastPingTime;
    uint256 public autoIrrevocableStartTime;

    // Fund management state
    RebalanceLimit public rebalanceLimit;

    // Beneficiary management state
    IGrantor.BeneficiarySettings public beneficiarySettings;
    uint256 public lastWithdrawalTime;

    // Modifiers
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

    modifier onlyProtector() {
        require(msg.sender == protector, "Only protector");
        _;
    }

    // IGrantor implementations
    function initialize(address grantorAddress) external override {
        if (grantorAddress == address(0)) {
            revert AddressZero();
        }
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        grantor = grantorAddress;
        isInitialized = true;
    }

    function initaialize(address grantorAddress, address beneficiaryAddress) external override {
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

    function initialize(address grantorAddress, address beneficiaryAddress, address trusteeAddress) external override {
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

    function initialize(
        address grantorAddress,
        address beneficiaryAddress,
        address trusteeAddress,
        address protectorAddress
    ) external override {
        if (
            grantorAddress == address(0) || beneficiaryAddress == address(0) || trusteeAddress == address(0)
                || protectorAddress == address(0)
        ) {
            revert AddressZero();
        }
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        grantor = grantorAddress;
        beneficiary = beneficiaryAddress;
        trustee = trusteeAddress;
        protector = protectorAddress;
        isInitialized = true;
    }

    function revoke(address moneyWithdrawTo) external override onlyInitialized onlyGrantor {
        if (!this.revocable()) {
            revert Irrevocable();
        }
        if (moneyWithdrawTo == address(0)) {
            revert AddressZero();
        }
        // transfer all the money, WBTC, WETH, USDT, USDC to the moneyWithdrawTo address
    }

    /**
     * @notice Set the trust to irrevocable.
     * @dev Set the trust to irrevocable.
     */
    function setToIrrevocable() external override onlyInitialized onlyGrantor {
        isIrrevocable = true;
    }

    /**
     * @notice Set the trust to irrevocable after no ping.
     * @dev Set the trust to irrevocable after no ping.
     * @param pingSeconds The number of seconds after no ping.
     */
    function setAutoIrrevocableAfterNoPing(uint256 pingSeconds) external override onlyInitialized onlyGrantor {
        autoIrrevocableAfterNoPing = pingSeconds;
        autoIrrevocableStartTime = block.timestamp;
    }

    /**
     * @notice Ping the trust.
     * @dev Ping the trust to make sure the Grantor is still alive, works for setAutoIrrevocableAfterNoPing.
     */
    function ping() external override onlyInitialized onlyGrantor {
        if (autoIrrevocableAfterNoPing == 0) {
            revert AutoIrrevocableAfterNoPingNotSet();
        }
        lastPingTime = block.timestamp;
    }

    function upgrade(address upgradeToContract) external override onlyInitialized onlyGrantor {
        if (upgradeToContract == address(0)) {
            revert AddressZero();
        }
        // Upgrade implementation, need to transfer all the money, parameters and subscribe info into the upgraded contract
    }

    function setTrustee(address trusteeAddress) external override onlyInitialized onlyGrantor {
        if (trusteeAddress == address(0)) {
            revert AddressZero();
        }
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

    function setBeneficiary(address beneficiaryAddress) external override onlyInitialized onlyGrantor {
        if (beneficiaryAddress == address(0)) {
            revert AddressZero();
        }
        beneficiary = beneficiaryAddress;
    }

    function setBeneficiarySettings(IGrantor.BeneficiarySettings memory beneficiarySettings_)
        external
        override
        onlyInitialized
        onlyGrantor
    {
        beneficiarySettings = beneficiarySettings_;
    }

    function setProtector(address protectorAddress) external override onlyInitialized onlyGrantor {
        if (protectorAddress == address(0)) {
            revert AddressZero();
        }
        protector = protectorAddress;
    }

    // ITrustee implementations
    function supply(address assetAddress, uint256 amount) external override onlyInitialized onlyTrustee {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        require(amount > 0, "Invalid amount");
    }

    function withdraw(address assetAddress, uint256 amount) external override onlyInitialized onlyTrustee {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        require(amount > 0, "Invalid amount");
    }

    function rebalance(AssetType from, AssetType to, uint256 sellAmount, uint256 buyAmount, uint256 slippage)
        external
        override
        onlyInitialized
        onlyTrustee
    {}

    function buy(
        AssetType buyAssetType,
        address sellAssetAddress,
        uint256 buyAmount,
        uint256 sellAmount,
        uint256 slippage
    ) external override onlyInitialized onlyTrustee {
        if (sellAssetAddress == address(0)) {
            revert AddressZero();
        }
    }

    function sendBeneficiary() external override onlyInitialized {}

    // IProtector implementations
    function pauseFundManagement() external override onlyInitialized onlyProtector {}

    function resumeFundManagement() external override onlyInitialized onlyProtector {}

    function replaceTrustee(address newTrusteeAddress) external override onlyInitialized onlyProtector {
        if (newTrusteeAddress == address(0)) {
            revert AddressZero();
        }
        trustee = newTrusteeAddress;
    }

    // ITrust implementations
    function revocable() external view override returns (bool) {
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
