// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {WETH} from "solmate/tokens/WETH.sol";
import {BittyV1VaultBase} from "./BittyV1VaultBase.sol";
import {IBittyV1Owner} from "./interfaces/IBittyV1Owner.sol";
import {IBittyV1Operator} from "./interfaces/IBittyV1Operator.sol";
import {
    IBittyV1Vault,
    AddressZero,
    OwnerAndOperatorMustDiffer,
    NotOperator,
    RiskControlLevel
} from "./interfaces/IBittyV1Vault.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {ManagerLogic} from "./logic/ManagerLogic.sol";
import {VaultStorage, ManagerStorage} from "./logic/Storages.sol";

/**
 * @title BittyV1Vault
 * @notice Core custody + payments: asset allowlist, scheduled payments and whitelisted recipients.
 *         Manager trading/yield lives in {BittyV1VaultDeFiFacet}, reached through this contract's fallback.
 */
contract BittyV1Vault is BittyV1VaultBase, IBittyV1Owner, IBittyV1Operator {
    using ManagerLogic for ManagerStorage;
    using VaultLogic for VaultStorage;

    modifier onlyOwnerOrOperator() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) && !_vault.isOperator(_msgSender())) {
            revert NotOperator();
        }
        _;
    }

    function _byOwner() private view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    receive() external payable {
        address weth = _vault.weth;
        if (msg.value > 0 && weth != address(0) && msg.sender != weth) {
            WETH(payable(weth)).deposit{value: msg.value}();
        }
    }

    fallback() external payable {
        address facet = _defiFacet;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function initialize(
        address owner,
        address guardAddress,
        address weth,
        address[] memory assetAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols,
        address defiFacet,
        RiskControlLevel riskLevel
    ) public initializer {
        _defiFacet = defiFacet;
        _vault.weth = weth;
        __AccessControl_init();
        __AccessControlDefaultAdminRules_init(OWNER_TRANSFER_DELAY, owner);

        _vault.initialize(guardAddress, riskLevel);
        if (assetAddresses.length > 0) {
            _vault.addAssets(assetAddresses);
        }

        _manager.initialize(guardAddress);
        if (lendingProtocols.length > 0) {
            _manager.addLendingProtocols(lendingProtocols);
        }
        if (stakingProtocols.length > 0) {
            _manager.addStakingProtocols(stakingProtocols);
        }
        if (ammProtocols.length > 0) {
            _manager.addAMMProtocols(ammProtocols);
        }
        if (intentProtocols.length > 0) {
            _manager.addIntentProtocols(intentProtocols);
        }
    }

    function addAssets(address[] memory assetAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.addAssets(assetAddresses);
        emit AssetsAdded(assetAddresses);
    }

    function removeAssets(address[] memory assetAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.removeAssets(assetAddresses);
        emit AssetsRemoved(assetAddresses);
    }

    function disableAddingAssets() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.disableAddingAssets();
        emit AssetsLocked();
    }

    function isAddingAssetsDisabled() external view returns (bool) {
        return _vault.addingAssetsDisabled;
    }

    function disableAddingProtocols() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _manager.disableAddingProtocols();
        emit ProtocolsLocked();
    }

    function isAddingProtocolsDisabled() external view returns (bool) {
        return _manager.addingProtocolsDisabled;
    }

    function send(address[] calldata recipients, address[] calldata assets, uint256[] calldata amounts)
        external
        override
        onlyOwnerOrOperator
    {
        if (_byOwner()) {
            _vault.send(recipients, assets, amounts);
        } else {
            _vault.proposeSend(recipients, assets, amounts);
        }
    }

    function approveSend(uint256 id) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.approveSend(id);
    }

    function cancelSend(uint256 id) external override onlyOwnerOrOperator {
        _vault.cancelSend(id, _byOwner());
    }

    function addScheduledPayment(IBittyV1Vault.ScheduledPayment calldata scheduledPayment_)
        external
        override
        onlyOwnerOrOperator
        returns (uint256 id)
    {
        return _vault.addScheduledPayment(scheduledPayment_, _byOwner());
    }

    function updateScheduledPayment(uint256 id, IBittyV1Vault.ScheduledPayment calldata scheduledPayment_)
        external
        override
        onlyOwnerOrOperator
    {
        _vault.updateScheduledPayment(id, scheduledPayment_, _byOwner());
    }

    function removeScheduledPayment(uint256 id) external override onlyOwnerOrOperator {
        _vault.removeScheduledPayment(id, _byOwner());
    }

    function approveScheduledPayment(uint256 id, bytes32 expectedHash) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.approveScheduledPayment(id, expectedHash);
    }

    function setScheduledPaymentProtection(uint256 protection) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setScheduledPaymentProtection(protection);
    }

    function setWhitelistedProtection(uint256 protection) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setWhitelistedProtection(protection);
    }

    function setMaxSendValue(uint256 value) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setMaxSendValue(value);
    }

    function setMaxScheduledValue(uint256 value) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setMaxScheduledValue(value);
    }

    function setMaxWhitelistedValue(uint256 value) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setMaxWhitelistedValue(value);
    }

    function setChangeTimelock(uint256 value) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setChangeTimelock(value);
    }

    function getRiskConfig()
        external
        view
        returns (
            uint64 scheduledPaymentProtection,
            uint64 whitelistedProtection,
            uint64 maxSendValue,
            uint64 maxScheduledValue,
            uint64 maxWhitelistedValue,
            uint64 changeTimelock
        )
    {
        return _vault.getRiskConfig();
    }

    function getRiskControlLevel() external view returns (RiskControlLevel) {
        return _vault.getRiskControlLevel();
    }

    function payScheduled(uint256 id) external {
        _vault.payScheduled(id);
    }

    function payScheduledAmount(uint256 id, uint256 amount) external {
        _vault.payScheduledAmount(id, amount);
    }

    function addWhitelistedRecipient(address recipient, address allowedAsset)
        external
        override
        onlyOwnerOrOperator
        returns (uint256 id)
    {
        return _vault.addWhitelistedRecipient(recipient, allowedAsset, _byOwner());
    }

    function updateWhitelistedRecipient(uint256 id, address recipient, address allowedAsset)
        external
        override
        onlyOwnerOrOperator
    {
        _vault.updateWhitelistedRecipient(id, recipient, allowedAsset, _byOwner());
    }

    function removeWhitelistedRecipient(uint256 id) external override onlyOwnerOrOperator {
        _vault.removeWhitelistedRecipient(id, _byOwner());
    }

    function approveWhitelistedRecipient(uint256 id) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.approveWhitelistedRecipient(id);
    }

    function sendToWhitelistedRecipient(uint256 id, address asset, uint256 amount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.sendToWhitelistedRecipient(id, asset, amount);
    }

    function getWhitelistedRecipient(uint256 id) external view returns (address recipient, address allowedAsset) {
        return _vault.getWhitelistedRecipient(id);
    }

    function setMinimalBalance(address assetAddress, uint256 newMinimalBalance)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _manager.setMinimalBalance(assetAddress, newMinimalBalance);
        emit MinimalBalanceSet(assetAddress, newMinimalBalance);
    }

    function setManager(
        address manager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _manager.setManager(manager, interval, maxStableCoinPerTrade, stableCoinInvestCap, expiredAt);
        emit TradeLimitSet(manager, interval, maxStableCoinPerTrade, stableCoinInvestCap, expiredAt);
    }

    function setFullManager(address manager) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _manager.setFullManager(manager);
        emit FullManagerAdded(manager);
    }

    function removeManager() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _manager.removeManager();
        emit ManagerRemoved();
    }

    function getManager() external view returns (address) {
        return _manager.manager;
    }

    function setOperator(address operator, uint256 interval, uint256 maxStableCoinPerPeriod)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (hasRole(DEFAULT_ADMIN_ROLE, operator)) revert OwnerAndOperatorMustDiffer();
        _vault.setOperator(operator, interval, maxStableCoinPerPeriod);
    }

    function updateOperator(address operator, uint256 interval, uint256 maxStableCoinPerPeriod)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.updateOperator(operator, interval, maxStableCoinPerPeriod);
    }

    function removeOperator(address operator) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.removeOperator(operator);
    }

    function getOperators() external view returns (address[] memory) {
        return _vault.getOperators();
    }

    function isOperator(address account) external view returns (bool) {
        return _vault.isOperator(account);
    }

    function addLendingProtocols(address[] memory lendingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _manager.addLendingProtocols(lendingProtocolAddresses);
        emit LendingProtocolsAdded(lendingProtocolAddresses);
    }

    function removeLendingProtocols(address[] memory lendingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _manager.removeLendingProtocols(lendingProtocolAddresses);
        emit LendingProtocolsRemoved(lendingProtocolAddresses);
    }

    function addStakingProtocols(address[] memory stakingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _manager.addStakingProtocols(stakingProtocolAddresses);
        emit StakingProtocolsAdded(stakingProtocolAddresses);
    }

    function removeStakingProtocols(address[] memory stakingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _manager.removeStakingProtocols(stakingProtocolAddresses);
        emit StakingProtocolsRemoved(stakingProtocolAddresses);
    }

    function addAMMProtocols(address[] memory ammProtocolAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _manager.addAMMProtocols(ammProtocolAddresses);
        emit AMMProtocolsAdded(ammProtocolAddresses);
    }

    function removeAMMProtocols(address[] memory ammProtocolAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _manager.removeAMMProtocols(ammProtocolAddresses);
        emit AMMProtocolsRemoved(ammProtocolAddresses);
    }

    function addIntentProtocols(address[] memory intentProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _manager.addIntentProtocols(intentProtocolAddresses);
        emit IntentProtocolsAdded(intentProtocolAddresses);
    }

    function removeIntentProtocols(address[] memory intentProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _manager.removeIntentProtocols(intentProtocolAddresses);
        emit IntentProtocolsRemoved(intentProtocolAddresses);
    }

    function wethAddress() external view returns (address) {
        return _vault.weth;
    }

    function getAssets() external view returns (address[] memory) {
        return _vault.getAssets();
    }

    function getStableCoins() external view returns (address[] memory) {
        return _vault.getStableCoins();
    }
}
