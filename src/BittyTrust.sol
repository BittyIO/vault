// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {ITrust} from "./interfaces/ITrust.sol";
import {ITrustee} from "./interfaces/ITrustee.sol";
import {IGrantor} from "./interfaces/IGrantor.sol";
import {IBeneficiary} from "./interfaces/IBeneficiary.sol";

// WETH interface
interface IWETH {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
}

contract BittyTrust is ITrust {
    error AddressZero();
    error AlreadyInitialized();
    error Irrevocable();
    error AutoIrrevocableAfterNoPingNotSet();
    error ENSResolutionFailed();
    error InvalidENSName();
    error ENSConfiguredUseENS();
    error StartDistributionTimestampAlreadySet();
    error BeneficiaryENSNotSet();
    error TrusteeENSNotSet();
    error ProtectorENSNotSet();
    error GrantorENSNotSet();
    error WETHNotSet();
    error WETHAlreadySet();

    // WETH contract address (configurable)
    IWETH public weth;

    // State variables
    address public grantor;
    address public trustee;
    address public beneficiary;

    bool public isInitialized;
    bool public isIrrevocable;
    uint256 public autoIrrevocableAfterNoPing;
    uint256 public lastPingTime;
    uint256 public autoIrrevocableStartTime;

    // Fund management state
    RebalanceLimit public rebalanceLimit;

    // Beneficiary management state
    IBeneficiary.BeneficiarySettings public beneficiarySettings;
    uint256 public lastWithdrawalTime;
    uint256 public startDistributionTimestamp;

    // Modifiers
    modifier onlyInitialized() {
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

    modifier onlyTrustee() {
        require(msg.sender == trustee, "Only trustee");
        _;
    }

    /**
     * @notice Set the WETH contract address.
     * @dev Can only be called once, before or during initialization.
     * @param wethAddress The WETH contract address.
     */
    function setWETH(address wethAddress) external {
        if (wethAddress == address(0)) {
            revert AddressZero();
        }
        if (address(weth) != address(0)) {
            revert WETHAlreadySet();
        }
        weth = IWETH(wethAddress);
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

    function setStartDistributionTimestamp(uint256 startDistributionTimestamp_)
        external
        override
        onlyInitialized
        onlyGrantor
    {
        if (startDistributionTimestamp != 0) {
            revert StartDistributionTimestampAlreadySet();
        }
        startDistributionTimestamp = startDistributionTimestamp_;
    }

    function distributionStarted() external view override returns (bool) {
        return block.timestamp >= startDistributionTimestamp;
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

    function setGrantor(address grantorAddress) external override onlyInitialized onlyGrantor {
        if (grantorAddress == address(0)) {
            revert AddressZero();
        }
        grantor = grantorAddress;
    }

    function setTrustee(address trusteeAddress) external override onlyInitialized onlyGrantor {
        if (!this.revocable()) {
            revert Irrevocable();
        }
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

    function setBeneficiarySettings(IBeneficiary.BeneficiarySettings memory beneficiarySettings_)
        external
        override
        onlyInitialized
        onlyGrantor
    {
        beneficiarySettings = beneficiarySettings_;
    }

    // IBeneficiary implementations
    function changeBeneficiaryAddress(address newBeneficiaryAddress)
        external
        override
        onlyInitialized
        onlyBeneficiary
    {
        if (newBeneficiaryAddress == address(0)) {
            revert AddressZero();
        }
        beneficiary = newBeneficiaryAddress;
    }

    function getMoney() external override onlyInitialized onlyBeneficiary {
        // TODO: Implement get money logic
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

    function rebalance(
        AssetType, /* from */
        AssetType, /* to */
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 slippage
    )
        external
        override
        onlyInitialized
        onlyTrustee
    {
        // TODO: Implement rebalancing logic
        // This would typically involve:
        // 1. Validating rebalance parameters
        // 2. Checking rebalance limits
        // 3. Executing trades through DEX (e.g., Uniswap)
        // 4. Updating asset balances
        require(sellAmount > 0, "Invalid sell amount");
        require(buyAmount > 0, "Invalid buy amount");
        require(slippage <= 10000, "Slippage too high"); // Max 100% slippage
    }

    function buy(
        AssetType, /* buyAssetType */
        address sellAssetAddress,
        uint256 buyAmount,
        uint256 sellAmount,
        uint256 slippage
    )
        external
        override
        onlyInitialized
        onlyTrustee
    {
        if (sellAssetAddress == address(0)) {
            revert AddressZero();
        }
        require(buyAmount > 0, "Invalid buy amount");
        require(sellAmount > 0, "Invalid sell amount");
        require(slippage <= 10000, "Slippage too high"); // Max 100% slippage

        // TODO: Implement buying logic
        // This would typically involve:
        // 1. Validating asset types and amounts
        // 2. Checking sufficient balance of sell asset
        // 3. Executing trade through DEX (e.g., Uniswap)
        // 4. Updating asset balances
    }

    function changeTrusteeAddress(address newTrusteeAddress) external override onlyInitialized onlyTrustee {
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

    /**
     * @notice Get the ETH balance of the trust.
     * @dev Get the ETH balance of the trust.
     * @return The ETH balance of the trust.
     */
    function getETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Convert ETH to WETH.
     * @dev Convert all ETH in the trust to WETH.
     */
    function turnETHToWETH() external onlyInitialized onlyTrustee {
        if (address(weth) == address(0)) {
            revert WETHNotSet();
        }
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            weth.deposit{value: ethBalance}();
        }
    }

    /**
     * @notice Get the WETH balance of the trust.
     * @dev Get the WETH balance of the trust.
     * @return The WETH balance of the trust.
     */
    function getWETHBalance() external view returns (uint256) {
        if (address(weth) == address(0)) {
            revert WETHNotSet();
        }
        return weth.balanceOf(address(this));
    }

    /**
     * @notice Receive ETH transfers.
     * @dev Allow the trust to receive ETH.
     */
    receive() external payable {
        // Trust can receive ETH
    }

    /**
     * @notice Fallback function for ETH transfers.
     * @dev Fallback function for ETH transfers.
     */
    fallback() external payable {
        // Trust can receive ETH
    }
}
