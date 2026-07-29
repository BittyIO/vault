// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {WETH} from "solmate/tokens/WETH.sol";
import {BittyV1VaultBase} from "./BittyV1VaultBase.sol";
import {IBittyV1Owner} from "./interfaces/IBittyV1Owner.sol";
import {IBittyV1PayoutOperator} from "./interfaces/IBittyV1PayoutOperator.sol";
import {
    IBittyV1Vault,
    AddressZero,
    OwnerAndPayoutOperatorMustDiffer,
    NotPayoutOperator,
    RiskControlLevel
} from "./interfaces/IBittyV1Vault.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultStorage, AssetManagerStorage} from "./logic/Storages.sol";

/**
 * @title BittyV1Vault
 * @notice Core custody + payments: asset allowlist, scheduled payments and whitelisted recipients.
 *         Asset manager trading/yield lives in {BittyV1VaultDeFiFacet}, reached through this contract's fallback.
 */
contract BittyV1Vault is BittyV1VaultBase, IBittyV1Owner, IBittyV1PayoutOperator {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;

    modifier onlyOwnerOrPayoutOperator() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) && !_vault.isPayoutOperator(_msgSender())) {
            revert NotPayoutOperator();
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

    /**
     * @notice Wrap any native ETH the vault is holding into WETH.
     * @dev receive() auto-wraps incoming ETH, but ETH that arrived before the
     *      vault was deployed (e.g. a deposit sent to the counterfactual address
     *      ahead of activation) sits as raw native ETH that the vault's
     *      WETH-denominated ETH accounting can't spend. This converts that balance
     *      to WETH. Permissionless — it only moves the vault's own ETH into its own
     *      WETH, so there's nothing to gate.
     */
    function ETHToWETH() external {
        address weth = _vault.weth;
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0 && weth != address(0)) {
            WETH(payable(weth)).deposit{value: ethBalance}();
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

        _assetManager.initialize(guardAddress);
        if (lendingProtocols.length > 0) {
            _assetManager.addLendingProtocols(lendingProtocols);
        }
        if (stakingProtocols.length > 0) {
            _assetManager.addStakingProtocols(stakingProtocols);
        }
        if (ammProtocols.length > 0) {
            _assetManager.addAMMProtocols(ammProtocols);
        }
        if (intentProtocols.length > 0) {
            _assetManager.addIntentProtocols(intentProtocols);
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
        _assetManager.disableAddingProtocols();
        emit ProtocolsLocked();
    }

    function isAddingProtocolsDisabled() external view returns (bool) {
        return _assetManager.addingProtocolsDisabled;
    }

    function send(address[] calldata recipients, address[] calldata assets, uint256[] calldata amounts)
        external
        override
        onlyOwnerOrPayoutOperator
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

    function cancelSend(uint256 id) external override onlyOwnerOrPayoutOperator {
        _vault.cancelSend(id, _byOwner());
    }

    function addScheduledPayment(IBittyV1Vault.ScheduledPayment calldata scheduledPayment_)
        external
        override
        onlyOwnerOrPayoutOperator
        returns (uint256 id)
    {
        return _vault.addScheduledPayment(scheduledPayment_, _byOwner());
    }

    function updateScheduledPayment(uint256 id, IBittyV1Vault.ScheduledPayment calldata scheduledPayment_)
        external
        override
        onlyOwnerOrPayoutOperator
    {
        _vault.updateScheduledPayment(id, scheduledPayment_, _byOwner());
    }

    function removeScheduledPayment(uint256 id) external override onlyOwnerOrPayoutOperator {
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
        onlyOwnerOrPayoutOperator
        returns (uint256 id)
    {
        return _vault.addWhitelistedRecipient(recipient, allowedAsset, _byOwner());
    }

    function updateWhitelistedRecipient(uint256 id, address recipient, address allowedAsset)
        external
        override
        onlyOwnerOrPayoutOperator
    {
        _vault.updateWhitelistedRecipient(id, recipient, allowedAsset, _byOwner());
    }

    function removeWhitelistedRecipient(uint256 id) external override onlyOwnerOrPayoutOperator {
        _vault.removeWhitelistedRecipient(id, _byOwner());
    }

    function approveWhitelistedRecipient(uint256 id, bytes32 expectedHash)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.approveWhitelistedRecipient(id, expectedHash);
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
        _assetManager.setMinimalBalance(assetAddress, newMinimalBalance);
        emit MinimalBalanceSet(assetAddress, newMinimalBalance);
    }

    function setAssetManager(
        address assetManager,
        uint256 interval,
        uint256 maxStableCoinPerTrade,
        uint256 stableCoinInvestCap,
        uint256 expiredAt
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.setAssetManager(assetManager, interval, maxStableCoinPerTrade, stableCoinInvestCap, expiredAt);
        emit TradeLimitSet(assetManager, interval, maxStableCoinPerTrade, stableCoinInvestCap, expiredAt);
    }

    function setFullAssetManager(address assetManager) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.setFullAssetManager(assetManager);
        emit FullAssetManagerAdded(assetManager);
    }

    function removeAssetManager() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.removeAssetManager();
        emit AssetManagerRemoved();
    }

    function getAssetManager() external view returns (address) {
        return _assetManager.assetManager;
    }

    function setPayoutOperator(address payoutOperator, uint256 interval, uint256 maxStableCoinPerPeriod)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (hasRole(DEFAULT_ADMIN_ROLE, payoutOperator)) revert OwnerAndPayoutOperatorMustDiffer();
        _vault.setPayoutOperator(payoutOperator, interval, maxStableCoinPerPeriod);
    }

    function updatePayoutOperator(address payoutOperator, uint256 interval, uint256 maxStableCoinPerPeriod)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.updatePayoutOperator(payoutOperator, interval, maxStableCoinPerPeriod);
    }

    function removePayoutOperator(address payoutOperator) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.removePayoutOperator(payoutOperator);
    }

    function getPayoutOperators() external view returns (address[] memory) {
        return _vault.getPayoutOperators();
    }

    function isPayoutOperator(address account) external view returns (bool) {
        return _vault.isPayoutOperator(account);
    }

    function addLendingProtocols(address[] memory lendingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addLendingProtocols(lendingProtocolAddresses);
        emit LendingProtocolsAdded(lendingProtocolAddresses);
    }

    function removeLendingProtocols(address[] memory lendingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.removeLendingProtocols(lendingProtocolAddresses);
        emit LendingProtocolsRemoved(lendingProtocolAddresses);
    }

    function addStakingProtocols(address[] memory stakingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addStakingProtocols(stakingProtocolAddresses);
        emit StakingProtocolsAdded(stakingProtocolAddresses);
    }

    function removeStakingProtocols(address[] memory stakingProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.removeStakingProtocols(stakingProtocolAddresses);
        emit StakingProtocolsRemoved(stakingProtocolAddresses);
    }

    function addAMMProtocols(address[] memory ammProtocolAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.addAMMProtocols(ammProtocolAddresses);
        emit AMMProtocolsAdded(ammProtocolAddresses);
    }

    function removeAMMProtocols(address[] memory ammProtocolAddresses) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.removeAMMProtocols(ammProtocolAddresses);
        emit AMMProtocolsRemoved(ammProtocolAddresses);
    }

    function addIntentProtocols(address[] memory intentProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addIntentProtocols(intentProtocolAddresses);
        emit IntentProtocolsAdded(intentProtocolAddresses);
    }

    function removeIntentProtocols(address[] memory intentProtocolAddresses)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.removeIntentProtocols(intentProtocolAddresses);
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
