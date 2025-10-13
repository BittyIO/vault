// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {ITrust} from "./interfaces/ITrust.sol";
import {ITrustee} from "./interfaces/ITrustee.sol";
import {IGrantor} from "./interfaces/IGrantor.sol";
import {IProtector} from "./interfaces/IProtector.sol";

// ENS interfaces
interface ENS {
    function resolver(bytes32 node) external view returns (address);
}

interface Resolver {
    function addr(bytes32 node) external view returns (address);
}

contract BittyTrust is ITrust {
    error AddressZero();
    error AlreadyInitialized();
    error Irrevocable();
    error AutoIrrevocableAfterNoPingNotSet();
    error ENSResolutionFailed();
    error InvalidENSName();
    error ENSConfiguredUseENS();

    // ENS registry address (Ethereum Mainnet)
    ENS private constant ens = ENS(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e);

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

    // ENS name storage
    string public grantorENS;
    string public trusteeENS;
    string public beneficiaryENS;
    string public protectorENS;

    // Fund management state
    RebalanceLimit public rebalanceLimit;

    // Beneficiary management state
    IGrantor.BeneficiarySettings public beneficiarySettings;
    uint256 public lastWithdrawalTime;

    // ENS helper functions
    function namehash(string memory name) internal pure returns (bytes32) {
        bytes32 node = 0x0000000000000000000000000000000000000000000000000000000000000000;
        if (bytes(name).length > 0) {
            bytes[] memory nameParts = splitString(name, ".");
            for (uint256 i = nameParts.length; i > 0; i--) {
                node = keccak256(abi.encodePacked(node, keccak256(nameParts[i - 1])));
            }
        }
        return node;
    }

    function splitString(string memory str, string memory delimiter) internal pure returns (bytes[] memory) {
        bytes memory strBytes = bytes(str);
        bytes memory delimiterBytes = bytes(delimiter);

        uint256 count = 1;
        for (uint256 i = 0; i < strBytes.length; i++) {
            if (i + delimiterBytes.length <= strBytes.length) {
                bool isMatch = true;
                for (uint256 j = 0; j < delimiterBytes.length; j++) {
                    if (strBytes[i + j] != delimiterBytes[j]) {
                        isMatch = false;
                        break;
                    }
                }
                if (isMatch) {
                    count++;
                    i += delimiterBytes.length - 1;
                }
            }
        }

        bytes[] memory result = new bytes[](count);
        uint256 resultIndex = 0;
        uint256 start = 0;

        for (uint256 i = 0; i < strBytes.length; i++) {
            if (i + delimiterBytes.length <= strBytes.length) {
                bool isMatch = true;
                for (uint256 j = 0; j < delimiterBytes.length; j++) {
                    if (strBytes[i + j] != delimiterBytes[j]) {
                        isMatch = false;
                        break;
                    }
                }
                if (isMatch) {
                    result[resultIndex] = new bytes(i - start);
                    for (uint256 k = 0; k < i - start; k++) {
                        result[resultIndex][k] = strBytes[start + k];
                    }
                    resultIndex++;
                    start = i + delimiterBytes.length;
                    i += delimiterBytes.length - 1;
                }
            }
        }

        result[resultIndex] = new bytes(strBytes.length - start);
        for (uint256 k = 0; k < strBytes.length - start; k++) {
            result[resultIndex][k] = strBytes[start + k];
        }

        return result;
    }

    function resolveENS(string memory ensName) external view returns (address) {
        return _resolveENS(ensName);
    }

    function _resolveENS(string memory ensName) internal view returns (address) {
        if (bytes(ensName).length == 0) {
            revert InvalidENSName();
        }

        bytes32 node = namehash(ensName);
        address resolverAddress = ens.resolver(node);

        if (resolverAddress == address(0)) {
            revert ENSResolutionFailed();
        }

        Resolver resolver = Resolver(resolverAddress);
        address resolvedAddress = resolver.addr(node);

        if (resolvedAddress == address(0)) {
            revert ENSResolutionFailed();
        }

        return resolvedAddress;
    }

    function getCurrentGrantor() public view returns (address) {
        if (bytes(grantorENS).length > 0) {
            try this.resolveENS(grantorENS) returns (address resolvedAddress) {
                return resolvedAddress;
            } catch {
                return grantor;
            }
        }
        return grantor;
    }

    function getCurrentTrustee() public view returns (address) {
        if (bytes(trusteeENS).length > 0) {
            try this.resolveENS(trusteeENS) returns (address resolvedAddress) {
                return resolvedAddress;
            } catch {
                return trustee;
            }
        }
        return trustee;
    }

    function getCurrentBeneficiary() public view returns (address) {
        if (bytes(beneficiaryENS).length > 0) {
            try this.resolveENS(beneficiaryENS) returns (address resolvedAddress) {
                return resolvedAddress;
            } catch {
                return beneficiary;
            }
        }
        return beneficiary;
    }

    function getCurrentProtector() public view returns (address) {
        if (bytes(protectorENS).length > 0) {
            try this.resolveENS(protectorENS) returns (address resolvedAddress) {
                return resolvedAddress;
            } catch {
                return protector;
            }
        }
        return protector;
    }

    // Modifiers
    modifier onlyInitialized() {
        require(isInitialized, "Trust not initialized");
        _;
    }

    modifier onlyGrantor() {
        require(msg.sender == getCurrentGrantor(), "Only grantor");
        _;
    }

    modifier onlyTrustee() {
        require(msg.sender == getCurrentTrustee(), "Only trustee");
        _;
    }

    modifier onlyProtector() {
        require(msg.sender == getCurrentProtector(), "Only protector");
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

    function initializeWithENS(string memory grantorENSName) external {
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        grantor = _resolveENS(grantorENSName);
        grantorENS = grantorENSName;
        isInitialized = true;
    }

    function initializeWithENS(string memory grantorENSName, string memory beneficiaryENSName) external {
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        grantor = _resolveENS(grantorENSName);
        beneficiary = _resolveENS(beneficiaryENSName);
        grantorENS = grantorENSName;
        beneficiaryENS = beneficiaryENSName;
        isInitialized = true;
    }

    function initializeWithENS(
        string memory grantorENSName,
        string memory beneficiaryENSName,
        string memory trusteeENSName
    ) external {
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        grantor = _resolveENS(grantorENSName);
        beneficiary = _resolveENS(beneficiaryENSName);
        trustee = _resolveENS(trusteeENSName);
        grantorENS = grantorENSName;
        beneficiaryENS = beneficiaryENSName;
        trusteeENS = trusteeENSName;
        isInitialized = true;
    }

    function initializeWithENS(
        string memory grantorENSName,
        string memory beneficiaryENSName,
        string memory trusteeENSName,
        string memory protectorENSName
    ) external {
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        grantor = _resolveENS(grantorENSName);
        beneficiary = _resolveENS(beneficiaryENSName);
        trustee = _resolveENS(trusteeENSName);
        protector = _resolveENS(protectorENSName);
        grantorENS = grantorENSName;
        beneficiaryENS = beneficiaryENSName;
        trusteeENS = trusteeENSName;
        protectorENS = protectorENSName;
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
        if (bytes(trusteeENS).length > 0) {
            revert ENSConfiguredUseENS();
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
        if (bytes(beneficiaryENS).length > 0) {
            revert ENSConfiguredUseENS();
        }
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
        if (bytes(protectorENS).length > 0) {
            revert ENSConfiguredUseENS();
        }
        if (protectorAddress == address(0)) {
            revert AddressZero();
        }
        protector = protectorAddress;
    }

    function setTrusteeWithENS(string memory trusteeENSName) external onlyInitialized onlyGrantor {
        trustee = _resolveENS(trusteeENSName);
        trusteeENS = trusteeENSName;
    }

    function setBeneficiaryWithENS(string memory beneficiaryENSName) external onlyInitialized onlyGrantor {
        beneficiary = _resolveENS(beneficiaryENSName);
        beneficiaryENS = beneficiaryENSName;
    }

    function setProtectorWithENS(string memory protectorENSName) external onlyInitialized onlyGrantor {
        protector = _resolveENS(protectorENSName);
        protectorENS = protectorENSName;
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
        if (bytes(trusteeENS).length > 0) {
            revert ENSConfiguredUseENS();
        }
        if (newTrusteeAddress == address(0)) {
            revert AddressZero();
        }
        trustee = newTrusteeAddress;
    }

    function replaceTrusteeENS(string memory newTrusteeENSName) external onlyInitialized onlyProtector {
        trustee = _resolveENS(newTrusteeENSName);
        trusteeENS = newTrusteeENSName;
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
