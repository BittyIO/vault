// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IAssetManager} from "../../src/interfaces/IAssetManager.sol";
import {IBeneficiary} from "../../src/interfaces/IBeneficiary.sol";
import {IWhiteList} from "../../src/interfaces/IWhiteList.sol";
import {IMigrator} from "../../src/interfaces/IMigrator.sol";
import {IVersionizedVault} from "../../src/interfaces/IVersionizedVault.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";

/**
 * @title MockVault
 * @notice Mock vault contract that copies public storage from BittyVault
 * @dev This contract only exists to copy public storage values from the original vault
 *      It can receive ERC20 tokens and ETH transfers (for migration testing)
 */
contract MockVault is IVersionizedVault {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.UintSet;
    using Address for address;
    uint256 public version;
    // Trust contract public storage variables
    address public grantor;
    address public trustee;
    address public assetManager;
    IAssetManager.ManageFee public manageFee;
    address public beneficiary;
    bool public isInitialized;
    bool public isIrrevocable;
    uint256 public autoIrrevocableAfterNoPing;
    uint256 public lastPingTime;
    uint256 public autoIrrevocableStartTime;
    IBeneficiary.BeneficiarySettings public beneficiarySettings;
    uint256 public lastWithdrawalTime;
    uint256 public startDistributionTimestamp;
    uint256 public lastBaseFeeTime;
    uint256 public revenue;
    uint256 public lastRevenueTime;
    mapping(bytes32 => IBeneficiary.TriggerEvent) public beneficiaryTriggerEvents;
    mapping(uint256 => IBeneficiary.TimeEvent) public beneficiaryTimeEvents;
    EnumerableSet.Bytes32Set internal _triggerEventKeys;
    EnumerableSet.UintSet internal _timeEventKeys;

    // AssetManager contract public storage variables
    address public wethAddress;
    IWhiteList public whiteList;
    mapping(address => IAssetManager.AssetConfig) public assetConfigs;
    mapping(address => uint256) public lastRebalanceTimestamps;
    uint256 public lastRebalanceTimestamp;
    IAssetManager.RebalanceLimit public rebalanceLimit;
    EnumerableSet.AddressSet internal _assets;
    EnumerableSet.AddressSet internal _stableCoins;
    EnumerableSet.AddressSet internal _yieldProviders;
    EnumerableSet.AddressSet internal _swapProviders;
    EnumerableSet.AddressSet internal _assetConfigKeys;
    EnumerableSet.AddressSet internal _lastRebalanceTimestampKeys;
    bytes public args;

    // BittyVault contract public storage variables
    address public migrator;

    constructor(uint256 _version) {
        version = _version;
    }

    function migrateAssets(uint256 _toVersion) public override {
        address nextVault = IMigrator(migrator).versionVault(address(this), _toVersion);
        // Transfer all assets
        for (uint256 i = 0; i < _assets.length(); i++) {
            address token = _assets.at(i);
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).transfer(nextVault, balance);
            }
        }

        // Transfer all stableCoins
        for (uint256 i = 0; i < _stableCoins.length(); i++) {
            address token = _stableCoins.at(i);
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).transfer(nextVault, balance);
            }
        }

        // Transfer any remaining ETH
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool success,) = payable(nextVault).call{value: ethBalance}("");
            require(success, "ETH transfer failed");
        }
    }

    function createAndMigrate(uint256 _toVersion, string calldata _salt) external override returns (address) {
        bytes memory returnData = migrator.functionDelegateCall(
            abi.encodeWithSelector(IMigrator.createVersionVault.selector, address(this), _toVersion, _salt)
        );
        address nextVault = abi.decode(returnData, (address));
        migrateAssets(_toVersion);
        return nextVault;
    }

    function initialize(address previousVersionVaultAddress, bytes memory _args) external override {
        args = _args;
        version = abi.decode(_args, (uint256));
        // Cast to BittyVault interface to access public getters
        BittyVaultInterface vault = BittyVaultInterface(previousVersionVaultAddress);

        // Copy Trust contract storage
        grantor = vault.grantor();
        trustee = vault.trustee();
        assetManager = vault.assetManager();
        manageFee = vault.manageFee();
        beneficiary = vault.beneficiary();
        isInitialized = vault.isInitialized();
        isIrrevocable = vault.isIrrevocable();
        autoIrrevocableAfterNoPing = vault.autoIrrevocableAfterNoPing();
        lastPingTime = vault.lastPingTime();
        autoIrrevocableStartTime = vault.autoIrrevocableStartTime();
        beneficiarySettings = vault.beneficiarySettings();
        lastWithdrawalTime = vault.lastWithdrawalTime();
        startDistributionTimestamp = vault.startDistributionTimestamp();
        lastBaseFeeTime = vault.lastBaseFeeTime();
        revenue = vault.revenue();
        lastRevenueTime = vault.lastRevenueTime();

        // Copy beneficiaryTriggerEvents mapping
        bytes32[] memory triggerEventKeys = vault.getAllTriggerEventKeys();
        for (uint256 i = 0; i < triggerEventKeys.length; i++) {
            bytes32 eventKey = triggerEventKeys[i];
            // Access struct fields individually (public mapping getter returns tuple)
            (address triggerAddress, uint256 amount, bool isPercentage) = vault.beneficiaryTriggerEvents(eventKey);
            beneficiaryTriggerEvents[eventKey] =
                IBeneficiary.TriggerEvent({triggerAddress: triggerAddress, amount: amount, isPercentage: isPercentage});
            _triggerEventKeys.add(eventKey);
        }

        // Copy beneficiaryTimeEvents mapping
        uint256[] memory timeEventKeys = vault.getAllTimeEventKeys();
        for (uint256 i = 0; i < timeEventKeys.length; i++) {
            uint256 timestamp = timeEventKeys[i];
            // Access struct fields individually (public mapping getter returns tuple)
            (uint256 amount, bool isPercentage) = vault.beneficiaryTimeEvents(timestamp);
            beneficiaryTimeEvents[timestamp] = IBeneficiary.TimeEvent({amount: amount, isPercentage: isPercentage});
            _timeEventKeys.add(timestamp);
        }

        // Copy AssetManager contract storage
        wethAddress = vault.wethAddress();
        whiteList = vault.whiteList();
        lastRebalanceTimestamp = vault.lastRebalanceTimestamp();
        rebalanceLimit = vault.rebalanceLimit();

        // Copy assetConfigs mapping
        address[] memory assetConfigKeys = vault.getAllAssetConfigKeys();
        for (uint256 i = 0; i < assetConfigKeys.length; i++) {
            address assetAddress = assetConfigKeys[i];
            // Access struct fields individually (public mapping getter returns tuple)
            (uint256 minimalBalance, uint256 minimalDurationBetweenRebalances) = vault.assetConfigs(assetAddress);
            assetConfigs[assetAddress] = IAssetManager.AssetConfig({
                minimalBalance: minimalBalance, minimalDurationBetweenRebalances: minimalDurationBetweenRebalances
            });
            _assetConfigKeys.add(assetAddress);
        }

        // Copy lastRebalanceTimestamps mapping
        address[] memory lastRebalanceTimestampKeys = vault.getAllLastRebalanceTimestampKeys();
        for (uint256 i = 0; i < lastRebalanceTimestampKeys.length; i++) {
            address assetAddress = lastRebalanceTimestampKeys[i];
            lastRebalanceTimestamps[assetAddress] = vault.lastRebalanceTimestamps(assetAddress);
            _lastRebalanceTimestampKeys.add(assetAddress);
        }

        // Copy _assets, _stableCoins, _yieldProviders, _swapProviders
        address[] memory assets = vault.getAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            _assets.add(assets[i]);
        }

        address[] memory stableCoins = vault.getStableCoins();
        for (uint256 i = 0; i < stableCoins.length; i++) {
            _stableCoins.add(stableCoins[i]);
        }

        address[] memory yieldProviders = vault.getYieldProviders();
        for (uint256 i = 0; i < yieldProviders.length; i++) {
            _yieldProviders.add(yieldProviders[i]);
        }

        address[] memory swapProviders = vault.getSwapProviders();
        for (uint256 i = 0; i < swapProviders.length; i++) {
            _swapProviders.add(swapProviders[i]);
        }

        // Copy BittyVault contract storage
        migrator = vault.migrator();
    }

    // Getter methods for testing
    function getAssets() external view returns (address[] memory) {
        return _assets.values();
    }

    function getStableCoins() external view returns (address[] memory) {
        return _stableCoins.values();
    }

    function getYieldProviders() external view returns (address[] memory) {
        return _yieldProviders.values();
    }

    function getSwapProviders() external view returns (address[] memory) {
        return _swapProviders.values();
    }

    // Implement getter methods for trigger and time event keys
    function getAllTriggerEventKeys() external view returns (bytes32[] memory) {
        return _triggerEventKeys.values();
    }

    function getAllTimeEventKeys() external view returns (uint256[] memory) {
        return _timeEventKeys.values();
    }

    function getAllAssetConfigKeys() external view returns (address[] memory) {
        return _assetConfigKeys.values();
    }

    function getAllLastRebalanceTimestampKeys() external view returns (address[] memory) {
        return _lastRebalanceTimestampKeys.values();
    }

    // Allow receiving ETH
    receive() external payable {}
    fallback() external payable {}
}

/**
 * @notice Interface to access BittyVault public getters
 */
interface BittyVaultInterface {
    // Trust getters
    function grantor() external view returns (address);
    function trustee() external view returns (address);
    function assetManager() external view returns (address);
    function manageFee() external view returns (IAssetManager.ManageFee memory);
    function beneficiary() external view returns (address);
    function isInitialized() external view returns (bool);
    function isIrrevocable() external view returns (bool);
    function autoIrrevocableAfterNoPing() external view returns (uint256);
    function lastPingTime() external view returns (uint256);
    function autoIrrevocableStartTime() external view returns (uint256);
    function beneficiarySettings() external view returns (IBeneficiary.BeneficiarySettings memory);
    function lastWithdrawalTime() external view returns (uint256);
    function startDistributionTimestamp() external view returns (uint256);
    function lastBaseFeeTime() external view returns (uint256);
    function revenue() external view returns (uint256);
    function lastRevenueTime() external view returns (uint256);
    function beneficiaryTriggerEvents(bytes32)
        external
        view
        returns (address triggerAddress, uint256 amount, bool isPercentage);
    function beneficiaryTimeEvents(uint256) external view returns (uint256 amount, bool isPercentage);
    function getAllTimeEventKeys() external view returns (uint256[] memory);
    function getAllTriggerEventKeys() external view returns (bytes32[] memory);

    // AssetManager getters
    function wethAddress() external view returns (address);
    function whiteList() external view returns (IWhiteList);
    function assetConfigs(address)
        external
        view
        returns (uint256 minimalBalance, uint256 minimalDurationBetweenRebalances);
    function lastRebalanceTimestamps(address) external view returns (uint256);
    function lastRebalanceTimestamp() external view returns (uint256);
    function rebalanceLimit() external view returns (IAssetManager.RebalanceLimit memory);
    function getAllAssetConfigKeys() external view returns (address[] memory);
    function getAllLastRebalanceTimestampKeys() external view returns (address[] memory);
    function getAssets() external view returns (address[] memory);
    function getStableCoins() external view returns (address[] memory);
    function getYieldProviders() external view returns (address[] memory);
    function getSwapProviders() external view returns (address[] memory);

    // BittyVault getters
    function migrator() external view returns (address);
}

