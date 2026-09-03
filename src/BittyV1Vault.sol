// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1VaultBase} from "./BittyV1VaultBase.sol";
import {IBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol";
import {DeFiLogic} from "./logic/DeFiLogic.sol";
import {PaymentLogic} from "./logic/PaymentLogic.sol";
import {ScheduledPaymentLogic} from "./logic/ScheduledPaymentLogic.sol";
import {WhitelistLogic} from "./logic/WhitelistLogic.sol";
import {GaslessLogic} from "./logic/GaslessLogic.sol";
import {RiskLogic} from "./logic/RiskLogic.sol";
import {SubVaultRegistryLogic} from "./logic/SubVaultRegistryLogic.sol";
import {BittyStorage} from "./logic/BittyStorage.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IBittyV1Owner} from "./interfaces/IBittyV1Owner.sol";
import {
    IBittyV1Vault,
    AddressZero,
    ArrayLengthMismatch,
    InsufficientBalance,
    NotPayoutOperator,
    NotTrustedForwarder,
    InvalidRelayedCalldata,
    PendingOwnerIsPayoutOperator,
    OwnerAndPayoutOperatorMustDiffer
} from "./interfaces/IBittyV1Vault.sol";

interface IAutoYieldTrigger {
    function autoYield(address asset) external;
}

/**
 * @title BittyV1Vault
 * @notice The main vault: owner payments + the owner's own DeFi (reached through fallback → shared
 *         {BittyV1VaultDeFiFacet}) + the sub-vault registry + curated/timelocked/freezable UUPS upgrades
 *         (from {BittyV1VaultBase}). Payouts to arbitrary external addresses live only here and are
 *         owner/payout-operator gated; sub vaults can never reach them.
 * @dev Renamed to BittyV1Vault at cutover.
 */
contract BittyV1Vault is BittyV1VaultBase, IBeacon {
    address public immutable DEFI_FACET;
    address public immutable SUB_VAULT_IMPL;

    constructor(address defiFacet, address subVaultImpl) {
        DEFI_FACET = defiFacet;
        SUB_VAULT_IMPL = subVaultImpl;
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address weth_,
        bool allowlistEnabled,
        address activationAsset,
        uint256 activationAmount
    ) external initializer {
        if (owner_ == address(0) || weth_ == address(0)) revert AddressZero();
        __Ownable_init(owner_);
        PaymentLogic.initialize(weth_);
        DeFiLogic.initialize(allowlistEnabled);
        if (activationAsset != address(0) && activationAmount != 0) {
            GaslessLogic.payActivationFee(activationAsset, activationAmount);
        }
        if (allowlistEnabled) {
            if (activationAsset != address(0)) {
                DeFiLogic.listInitialAsset(activationAsset);
            }
            DeFiLogic.listInitialAsset(weth_);
        }
        uint256 bal = address(this).balance;
        if (bal > 0) WETH(payable(weth_)).deposit{value: bal}();
    }

    modifier onlyOwnerOrPayoutOperator() {
        if (_msgSender() != owner() && !PaymentLogic.isPayoutOperator(_msgSender())) revert NotPayoutOperator();
        _;
    }

    function _byOwner() private view returns (bool) {
        return _msgSender() == owner();
    }

    function _weth() private view returns (address) {
        return BittyStorage.vault().weth;
    }

    function _payoutAsset(address asset) private view returns (address) {
        return asset == address(0) ? _weth() : asset;
    }

    function acceptOwnership() public override {
        if (PaymentLogic.isPayoutOperator(_msgSender())) revert PendingOwnerIsPayoutOperator();
        super.acceptOwnership();
    }

    function renounceVaultOwnership(uint256 rescueScheduledPaymentId) external onlyOwner {
        DeFiLogic.clearDelegates();
        PaymentLogic.prepareRenounce(rescueScheduledPaymentId);
        address formerOwner = _msgSender();
        _transferOwnership(address(0));
        emit IBittyV1Owner.OwnershipRenounced(formerOwner);
    }

    receive() external payable {
        address weth = _weth();
        if (msg.value > 0 && msg.sender != weth) {
            WETH(payable(weth)).deposit{value: msg.value}();
            try IAutoYieldTrigger(address(this)).autoYield(weth) {} catch {}
        }
    }

    function ETHToWETH() external {
        address weth = _weth();
        uint256 bal = address(this).balance;
        if (bal > 0 && weth != address(0)) WETH(payable(weth)).deposit{value: bal}();
    }

    fallback() external payable {
        if (msg.data.length < 24 && msg.sender == trustedForwarder()) revert InvalidRelayedCalldata();
        address facet = DEFI_FACET;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function enableAllowlist() external onlyOwner {
        DeFiLogic.enableAllowlist();
    }

    function disableAllowlist() external onlyOwner {
        DeFiLogic.disableAllowlist(RiskLogic.effectiveChangeTimelock());
    }

    function batchSend(
        address[] calldata recipients,
        address[] calldata assets,
        uint256[] calldata amounts,
        address[][] calldata withdrawProtocols,
        uint256[][] calldata withdrawAmounts
    ) external onlyOwnerOrPayoutOperator {
        if (_byOwner()) {
            _pullFromPositions(assets, withdrawProtocols, withdrawAmounts);
            PaymentLogic.send(recipients, assets, amounts);
        } else {
            PaymentLogic.proposeSend(recipients, assets, amounts, _msgSender());
        }
    }

    function send(
        address recipient,
        address asset,
        uint256 amount,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) external onlyOwnerOrPayoutOperator {
        if (_byOwner()) {
            _pullOneFromPositions(asset, withdrawProtocols, withdrawAmounts);
            address[] memory r = new address[](1);
            address[] memory a = new address[](1);
            uint256[] memory m = new uint256[](1);
            r[0] = recipient;
            a[0] = asset;
            m[0] = amount;
            PaymentLogic.send(r, a, m);
        } else {
            PaymentLogic.proposeSendOne(recipient, asset, amount, _msgSender());
        }
    }

    function reviewSends(uint256[] calldata approveIds, uint256[] calldata cancelIds) external onlyOwner {
        PaymentLogic.reviewSends(approveIds, cancelIds, _msgSender());
    }

    function approveSend(uint256 id) external onlyOwner {
        PaymentLogic.approveSendOne(id);
    }

    function cancelSend(uint256 id) external onlyOwnerOrPayoutOperator {
        PaymentLogic.cancelSendOne(id, _byOwner(), _msgSender());
    }

    function cancelSends(uint256[] calldata ids) external onlyOwnerOrPayoutOperator {
        PaymentLogic.cancelSends(ids, _byOwner(), _msgSender());
    }

    function addScheduledPayment(IBittyV1Vault.ScheduledPayment calldata sp)
        external
        onlyOwnerOrPayoutOperator
        returns (uint256)
    {
        return ScheduledPaymentLogic.addScheduledPaymentOne(sp, _byOwner(), _msgSender());
    }

    function updateScheduledPayments(uint256[] calldata ids, IBittyV1Vault.ScheduledPayment[] calldata sps)
        external
        onlyOwnerOrPayoutOperator
    {
        ScheduledPaymentLogic.updateScheduledPayments(ids, sps, _byOwner(), _msgSender());
    }

    function removeScheduledPayments(uint256[] calldata ids) external onlyOwnerOrPayoutOperator {
        ScheduledPaymentLogic.removeScheduledPayments(ids, _byOwner(), _msgSender());
    }

    function reviewScheduledPayments(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external onlyOwner {
        ScheduledPaymentLogic.reviewScheduledPayments(approveIds, expectedHashes, cancelIds, _msgSender());
    }

    function payScheduled(uint256 id, address[] calldata withdrawProtocols) external {
        (
            bool skipped,
            address recipient,
            address asset,
            address payoutToken,
            uint256 needed,
            uint256 have,
            bool allowPartial,
            uint256 count
        ) = ScheduledPaymentLogic.accrueScheduled(id, _msgSender(), withdrawProtocols.length > 0);
        if (skipped) return;

        bool native = asset == address(0);
        uint256 covered = have >= needed
            ? 0
            : _coverShortfall(withdrawProtocols, payoutToken, native ? address(this) : recipient, needed - have);

        uint256 raw = (have < needed ? have : needed) + covered;
        uint256 delivered = raw < needed ? raw : needed;
        if (delivered < needed && !allowPartial) revert InsufficientBalance();

        ScheduledPaymentLogic.payScheduledOut(asset, recipient, native ? delivered : (have < needed ? have : needed));
        emit IBittyV1Vault.ScheduledPaymentPaid(id, recipient, asset, delivered, count);
    }

    function payScheduledAmount(uint256 id, uint256 amount) external {
        ScheduledPaymentLogic.payScheduledAmount(id, amount, _msgSender());
    }

    function addWhitelistedRecipient(address recipient, address allowedAsset)
        external
        onlyOwnerOrPayoutOperator
        returns (uint256)
    {
        return WhitelistLogic.addWhitelistedRecipientOne(recipient, allowedAsset, _byOwner(), _msgSender());
    }

    function updateWhitelistedRecipients(
        uint256[] calldata ids,
        address[] calldata recipients,
        address[] calldata allowedAssets
    ) external onlyOwnerOrPayoutOperator {
        WhitelistLogic.updateWhitelistedRecipients(ids, recipients, allowedAssets, _byOwner(), _msgSender());
    }

    function removeWhitelistedRecipients(uint256[] calldata ids) external onlyOwnerOrPayoutOperator {
        WhitelistLogic.removeWhitelistedRecipients(ids, _byOwner(), _msgSender());
    }

    function reviewWhitelistedRecipients(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external onlyOwner {
        WhitelistLogic.reviewWhitelistedRecipients(approveIds, expectedHashes, cancelIds, _msgSender());
    }

    function sendToWhitelistedRecipient(
        uint256 id,
        address asset,
        uint256 amount,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) external onlyOwner {
        _pullOneFromPositions(asset, withdrawProtocols, withdrawAmounts);
        WhitelistLogic.sendToWhitelistedRecipientOne(id, asset, amount);
    }

    function updatePaymentRisk(IBittyV1Owner.PaymentRisk calldata paymentRisk) external onlyOwner {
        RiskLogic.updatePaymentRisk(paymentRisk);
    }

    function updatePayoutOperator(address payoutOperator, bool add) external onlyOwner {
        if (add && payoutOperator == owner()) revert OwnerAndPayoutOperatorMustDiffer();
        PaymentLogic.updatePayoutOperatorOne(payoutOperator, add);
        emit IBittyV1Owner.PayoutOperatorUpdated(payoutOperator, add);
    }

    function setGasless(address[] calldata assets, uint64 dailyLimit, uint64 maxFeePerOp) external onlyOwner {
        GaslessLogic.setGasless(assets, dailyLimit, maxFeePerOp);
    }

    function disableGasless() external onlyOwner {
        GaslessLogic.disableGasless();
    }

    function payRelayerFee(address asset, uint256 amount) external {
        if (msg.sender != trustedForwarder()) revert NotTrustedForwarder();
        GaslessLogic.payRelayerFee(asset, amount);
    }

    function retrieve721(address contractAddress, uint256 tokenId, address to) external onlyOwner {
        if (to == address(0)) revert AddressZero();
        DeFiLogic.checkNotProtocolNFT(contractAddress);
        IERC721(contractAddress).safeTransferFrom(address(this), to, tokenId);
        emit IBittyV1Owner.Retrieved721(contractAddress, tokenId, to);
    }

    function createSubVault(address subOwner, bool allowlistEnabled, uint64 expiresAt)
        external
        onlyOwner
        returns (uint256 subId, address account)
    {
        return SubVaultRegistryLogic.createSubVault(subOwner, allowlistEnabled, expiresAt);
    }

    function createSubVaultWithDeposits(
        address subOwner,
        bool allowlistEnabled,
        uint64 expiresAt,
        address[] calldata assets,
        uint256[] calldata amounts
    ) external onlyOwner returns (uint256 subId, address account) {
        if (assets.length != amounts.length) revert ArrayLengthMismatch();
        (subId, account) = SubVaultRegistryLogic.createSubVault(subOwner, allowlistEnabled, expiresAt);
        SubVaultRegistryLogic.fundSubVault(subId, assets, amounts);
    }

    function fundSubVault(uint256 subId, address[] calldata assets, uint256[] calldata amounts) external onlyOwner {
        SubVaultRegistryLogic.fundSubVault(subId, assets, amounts);
    }

    function recallFromSubVault(uint256 subId, address[] calldata assets, uint256[] calldata amounts)
        external
        onlyOwner
    {
        SubVaultRegistryLogic.recallFromSubVault(subId, assets, amounts);
    }

    function assignSubOwner(uint256 subId, address newOwner, uint64 expiresAt) external onlyOwner {
        SubVaultRegistryLogic.assignSubOwner(subId, newOwner, expiresAt);
    }

    function setSubOwnerExpiry(uint256 subId, uint64 expiresAt) external onlyOwner {
        SubVaultRegistryLogic.setSubOwnerExpiry(subId, expiresAt);
    }

    function setSubVaultGasless(uint256 subId, bool enabled) external onlyOwner {
        SubVaultRegistryLogic.setSubVaultGasless(subId, enabled);
    }

    function closeSubVault(uint256 subId) external onlyOwner {
        SubVaultRegistryLogic.closeSubVault(subId);
    }

    function implementation() external view override returns (address) {
        return SUB_VAULT_IMPL;
    }

    function _pullFromPositions(
        address[] calldata assets,
        address[][] calldata withdrawProtocols,
        uint256[][] calldata withdrawAmounts
    ) private {
        if (withdrawProtocols.length == 0 && withdrawAmounts.length == 0) {
            return;
        }
        uint256 n = assets.length;
        if (withdrawProtocols.length != n || withdrawAmounts.length != n) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < n; i++) {
            _pullOneFromPositions(assets[i], withdrawProtocols[i], withdrawAmounts[i]);
        }
    }

    function _pullOneFromPositions(
        address asset,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) private {
        if (withdrawProtocols.length != withdrawAmounts.length) {
            revert ArrayLengthMismatch();
        }
        address payoutAsset = _payoutAsset(asset);
        for (uint256 i = 0; i < withdrawProtocols.length; i++) {
            if (withdrawProtocols[i] != address(0) && withdrawAmounts[i] > 0) {
                DeFiLogic.withdraw(withdrawProtocols[i], payoutAsset, withdrawAmounts[i], address(this));
            }
        }
    }

    function _coverShortfall(address[] calldata withdrawProtocols, address payoutToken, address sink, uint256 shortfall)
        private
        returns (uint256 covered)
    {
        for (uint256 i = 0; i < withdrawProtocols.length && covered < shortfall; i++) {
            address protocol = withdrawProtocols[i];
            if (protocol == address(0)) continue;
            uint256 available = DeFiLogic.protocolBalance(protocol, payoutToken);
            if (available == 0) continue;
            uint256 remaining = shortfall - covered;
            covered += DeFiLogic.withdraw(protocol, payoutToken, available < remaining ? available : remaining, sink);
        }
    }

    function getRiskConfig()
        external
        view
        returns (uint64 newPaymentProtection, uint64 maxSendValue, uint64 changeTimelock, uint64 maxSendInterval)
    {
        return RiskLogic.getRiskConfig();
    }

    function getWhitelistedRecipients(uint256[] calldata ids)
        external
        view
        returns (address[] memory recipients, address[] memory allowedAssets)
    {
        return WhitelistLogic.getWhitelistedRecipients(ids);
    }

    function gaslessConfig() external view returns (address[] memory assets, uint256 dailyLimit, uint256 maxFeePerOp) {
        return (GaslessLogic.getGaslessAssets(), GaslessLogic.gasBudgetDailyLimit(), GaslessLogic.maxFeePerOpValue());
    }

    function gasBudgetRemaining() external view returns (uint256) {
        return GaslessLogic.gasBudgetRemaining();
    }

    function isPayoutOperator(address account) external view returns (bool) {
        return PaymentLogic.isPayoutOperator(account);
    }

    function isStableCoinAllowed(address asset) external view returns (bool) {
        return DeFiLogic.stableCoinAllowed(asset);
    }

    function wethAddress() external view returns (address) {
        return _weth();
    }

    function getSubVault(uint256[] calldata subIds)
        external
        view
        returns (
            address[] memory accounts,
            address[] memory owners,
            uint64[] memory expiresAts,
            bool[] memory gaslessEnabled,
            bool[] memory closed
        )
    {
        return SubVaultRegistryLogic.getSubVault(subIds);
    }

    function subVaultOpenCount() external view returns (uint256) {
        return SubVaultRegistryLogic.openSubCount();
    }
}
