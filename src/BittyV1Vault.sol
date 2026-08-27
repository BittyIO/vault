// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {WETH} from "solmate/tokens/WETH.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {BittyV1VaultBase} from "./BittyV1VaultBase.sol";
import {IBittyV1Owner} from "./interfaces/IBittyV1Owner.sol";
import {IBittyV1PayoutOperator} from "./interfaces/IBittyV1PayoutOperator.sol";
import {
    IBittyV1Vault,
    AddressZero,
    ArrayLengthMismatch,
    OwnerAndPayoutOperatorMustDiffer,
    NotPayoutOperator,
    NotTrustedForwarder,
    InvalidRelayedCalldata,
    AutoYield
} from "./interfaces/IBittyV1Vault.sol";
import {VaultLogic} from "./logic/VaultLogic.sol";
import {AssetManagerLogic} from "./logic/AssetManagerLogic.sol";
import {VaultStorage, AssetManagerStorage} from "./logic/Storages.sol";
import {Multicall} from "openzeppelin-contracts/contracts/utils/Multicall.sol";
import {Context} from "openzeppelin-contracts/contracts/utils/Context.sol";

/**
 * @title BittyV1Vault
 * @notice Core custody + payments: asset allowlist, scheduled payments and whitelisted recipients.
 *         Asset manager trading/yield lives in {BittyV1VaultDeFiFacet}, reached through this contract's fallback.
 */
/**
 * @dev Batching comes from OpenZeppelin's {Multicall}: it self-delegatecalls each entry, so msg.sender
 *      and storage are the caller's throughout and every call is authorised exactly as it would be on
 *      its own — batching grants nothing. Since OZ 5.0.1 it also re-appends the ERC-2771 sender suffix
 *      to each sub-call, which a naive loop would drop, silently turning a relayed batch into calls
 *      attributed to the forwarder.
 *
 *      A generic batch rather than bespoke one-transaction helpers: the pairs worth batching (allow a
 *      token then approve the relayer for it, enter a position then set its yield route) are the
 *      client's to compose, and every helper we wrote for a specific pair became dead weight the
 *      moment the underlying step stopped being needed.
 */
contract BittyV1Vault is BittyV1VaultBase, Multicall, IBittyV1Owner, IBittyV1PayoutOperator {
    using AssetManagerLogic for AssetManagerStorage;
    using VaultLogic for VaultStorage;
    address public immutable AUTO_YIELD_KEEPER;

    address public immutable DEFI_FACET;

    error NotAutoYieldTrigger();

    constructor(address defiFacet, address autoYieldKeeper) {
        DEFI_FACET = defiFacet;
        AUTO_YIELD_KEEPER = autoYieldKeeper;
    }

    modifier onlyOwnerOrPayoutOperator() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) && !_vault.isPayoutOperator(_msgSender())) {
            revert NotPayoutOperator();
        }
        _;
    }

    function _byOwner() private view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    function renounceVaultOwnership(uint256 rescueScheduledPaymentId) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.prepareRenounce(rescueScheduledPaymentId);
        address formerOwner = _msgSender();

        address remainingManager = _assetManager.prepareRenounceAssetManager(_vault, formerOwner);
        _renounceOwner();

        emit AssetManagerSet(remainingManager, _assetManager.assetManagerExpiresAt);
        emit OwnershipRenounced(formerOwner);
    }

    receive() external payable {
        address weth = _vault.weth;
        if (msg.value > 0 && msg.sender != weth) {
            WETH(payable(weth)).deposit{value: msg.value}();
            try this.autoYield(weth) {} catch {}
        }
    }

    function autoYield(address assetAddress) external {
        _checkAutoYieldCaller();
        _assetManager.autoYieldOne(assetAddress);
    }

    function autoYields(address[] calldata assetAddresses) external {
        _checkAutoYieldCaller();
        _assetManager.autoYield(assetAddresses);
    }

    function payRelayerFee(address stableCoinAddress, uint256 amount) external {
        address forwarder = trustedForwarder();
        if (forwarder == address(0) || msg.sender != forwarder) revert NotTrustedForwarder();
        _vault.payRelayerFee(stableCoinAddress, amount);
    }

    function gasBudgetRemaining() external view returns (uint256) {
        return _vault.gasBudgetRemaining();
    }

    function setGasless(address[] calldata assets, uint64 dailyLimit, uint64 maxFeePerOp_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.setGasless(assets, dailyLimit, maxFeePerOp_);
    }

    function disableGasless() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.disableGasless();
    }

    function gaslessConfig() external view returns (address[] memory assets, uint256 dailyLimit, uint256 maxFeePerOp) {
        return (_vault.getGaslessAssets(), _vault.gasBudgetDailyLimit(), _vault.maxFeePerOpValue());
    }

    function ETHToWETH() external {
        address weth = _vault.weth;
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0 && weth != address(0)) {
            WETH(payable(weth)).deposit{value: ethBalance}();
        }
    }

    function _msgSender() internal view virtual override(BittyV1VaultBase, Context) returns (address) {
        return BittyV1VaultBase._msgSender();
    }

    function _msgData() internal view virtual override(BittyV1VaultBase, Context) returns (bytes calldata) {
        return BittyV1VaultBase._msgData();
    }

    function _contextSuffixLength() internal view virtual override(BittyV1VaultBase, Context) returns (uint256) {
        return BittyV1VaultBase._contextSuffixLength();
    }

    fallback() external payable {
        // Under 24 bytes there is no room for a selector plus the ERC-2771 suffix, so the facet would
        // dispatch on bytes taken from the appended address itself — a selector anyone can choose by
        // grinding a vanity key, not a function anyone encoded a call to. Nothing reachable that way is
        // dangerous today: every zero-argument facet function is a view, and the ABI decoder rejects
        // short calldata for the rest. That is a property of the facet as it stands, not a guarantee —
        // the first zero-argument state-changing function added there would be callable this way.
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

    function initialize(address owner, address weth, address asset, uint256 amount) public initializer {
        _vault.weth = weth;
        __AccessControl_init();
        _initOwner(owner);

        _vault.initialize();

        if (asset != address(0) && amount != 0) {
            _vault.payActivationFee(asset, amount);
        }

        _assetManager.initialize();
        _assetManager.initAssetManager(owner);

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            WETH(payable(weth)).deposit{value: ethBalance}();
        }
    }

    function updateAssets(address[] memory addAssets, address[] memory removeAssets)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.addAssets(addAssets);
        _vault.removeAssets(removeAssets);
        emit AssetsUpdated(addAssets, removeAssets);
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

    function batchSend(
        address[] calldata recipients,
        address[] calldata assets,
        uint256[] calldata amounts,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) external override onlyOwnerOrPayoutOperator {
        if (_byOwner()) {
            _pullFromPositions(assets, withdrawProtocols, withdrawAmounts);
            _vault.send(recipients, assets, amounts);
        } else {
            _vault.proposeSend(recipients, assets, amounts, _msgSender());
        }
    }

    function _pullFromPositions(
        address[] calldata assets,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) private {
        if (withdrawProtocols.length == 0 && withdrawAmounts.length == 0) {
            return;
        }
        uint256 n = assets.length;
        if (withdrawProtocols.length != n || withdrawAmounts.length != n) {
            revert ArrayLengthMismatch();
        }
        address self = address(this);
        for (uint256 i = 0; i < n; i++) {
            if (withdrawProtocols[i] != address(0) && withdrawAmounts[i] > 0) {
                _assetManager.withdraw(withdrawProtocols[i], _payoutAsset(assets[i]), withdrawAmounts[i], self);
            }
        }
    }

    function _pullOneFromPositions(
        address assetAddress,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) private {
        if (withdrawProtocols.length != withdrawAmounts.length) {
            revert ArrayLengthMismatch();
        }
        address asset = _payoutAsset(assetAddress);
        for (uint256 i = 0; i < withdrawProtocols.length; i++) {
            if (withdrawProtocols[i] != address(0) && withdrawAmounts[i] > 0) {
                _assetManager.withdraw(withdrawProtocols[i], asset, withdrawAmounts[i], address(this));
            }
        }
    }

    function _payoutAsset(address assetAddress) private view returns (address) {
        return assetAddress == address(0) ? _vault.weth : assetAddress;
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
            _vault.sendOne(recipient, asset, amount);
        } else {
            _vault.proposeSendOne(recipient, asset, amount, _msgSender());
        }
    }

    function sendToWhitelistedRecipient(
        uint256 id,
        address asset,
        uint256 amount,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pullOneFromPositions(asset, withdrawProtocols, withdrawAmounts);
        _vault.sendToWhitelistedRecipientOne(id, asset, amount);
    }

    function payScheduled(uint256 id, address[] calldata withdrawProtocols, uint256[] calldata withdrawAmounts)
        external
    {
        address asset = _vault.scheduledPaymentAsset(id);
        _pullOneFromPositions(asset, withdrawProtocols, withdrawAmounts);
        _vault.payScheduledOne(id, _msgSender());
    }

    function approveSend(uint256 id) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.approveSendOne(id);
    }

    function addScheduledPayment(IBittyV1Vault.ScheduledPayment calldata scheduledPayment)
        external
        onlyOwnerOrPayoutOperator
        returns (uint256)
    {
        return _vault.addScheduledPaymentOne(scheduledPayment, _byOwner(), _msgSender());
    }

    function addWhitelistedRecipient(address recipient, address allowedAsset)
        external
        onlyOwnerOrPayoutOperator
        returns (uint256)
    {
        return _vault.addWhitelistedRecipientOne(recipient, allowedAsset, _byOwner(), _msgSender());
    }

    function cancelSend(uint256 id) external onlyOwnerOrPayoutOperator {
        _vault.cancelSendOne(id, _byOwner(), _msgSender());
    }

    function _checkAutoYieldCaller() private view {
        if (msg.sender == address(this)) return;
        address sender = _msgSender();
        if (sender == AUTO_YIELD_KEEPER) return;
        if (hasRole(DEFAULT_ADMIN_ROLE, sender)) return;
        revert NotAutoYieldTrigger();
    }

    function setAutoYielding(AutoYield calldata route) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.setAutoYieldingOne(route);
    }

    function reviewSends(uint256[] calldata approveIds, uint256[] calldata cancelIds)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.reviewSends(approveIds, cancelIds, _msgSender());
    }

    function cancelSends(uint256[] calldata ids) external override onlyOwnerOrPayoutOperator {
        _vault.cancelSends(ids, _byOwner(), _msgSender());
    }

    function updateScheduledPayments(
        uint256[] calldata ids,
        IBittyV1Vault.ScheduledPayment[] calldata scheduledPayments_
    ) external override onlyOwnerOrPayoutOperator {
        _vault.updateScheduledPayments(ids, scheduledPayments_, _byOwner(), _msgSender());
    }

    function removeScheduledPayments(uint256[] calldata ids) external override onlyOwnerOrPayoutOperator {
        _vault.removeScheduledPayments(ids, _byOwner(), _msgSender());
    }

    function reviewScheduledPayments(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.reviewScheduledPayments(approveIds, expectedHashes, cancelIds, _msgSender());
    }

    function updatePaymentRisk(IBittyV1Owner.PaymentRisk calldata paymentRisk)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.updatePaymentRisk(paymentRisk);
    }

    function getRiskConfig()
        external
        view
        returns (uint64 newPaymentProtection, uint64 maxSendValue, uint64 changeTimelock, uint64 maxSendInterval)
    {
        return _vault.getRiskConfig();
    }

    function payScheduleds(
        uint256[] calldata ids,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) external {
        _pullScheduledFromPositions(ids, withdrawProtocols, withdrawAmounts);
        _vault.payScheduled(ids, _msgSender());
    }

    function _pullScheduledFromPositions(
        uint256[] calldata ids,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) private {
        if (withdrawProtocols.length == 0 && withdrawAmounts.length == 0) {
            return;
        }
        uint256 n = ids.length;
        if (withdrawProtocols.length != n || withdrawAmounts.length != n) {
            revert ArrayLengthMismatch();
        }
        address self = address(this);
        for (uint256 i = 0; i < n; i++) {
            if (withdrawProtocols[i] != address(0) && withdrawAmounts[i] > 0) {
                address asset = _payoutAsset(_vault.scheduledPaymentAsset(ids[i]));
                _assetManager.withdraw(withdrawProtocols[i], asset, withdrawAmounts[i], self);
            }
        }
    }

    function payScheduledAmount(uint256 id, uint256 amount) external {
        _vault.payScheduledAmount(id, amount, _msgSender());
    }

    function updateWhitelistedRecipients(
        uint256[] calldata ids,
        address[] calldata recipients,
        address[] calldata allowedAssets
    ) external override onlyOwnerOrPayoutOperator {
        _vault.updateWhitelistedRecipients(ids, recipients, allowedAssets, _byOwner(), _msgSender());
    }

    function removeWhitelistedRecipients(uint256[] calldata ids) external override onlyOwnerOrPayoutOperator {
        _vault.removeWhitelistedRecipients(ids, _byOwner(), _msgSender());
    }

    function reviewWhitelistedRecipients(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.reviewWhitelistedRecipients(approveIds, expectedHashes, cancelIds, _msgSender());
    }

    function getWhitelistedRecipients(uint256[] calldata ids)
        external
        view
        returns (address[] memory recipients, address[] memory allowedAssets)
    {
        return _vault.getWhitelistedRecipients(ids);
    }

    function setAutoYieldings(AutoYield[] calldata routes) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.setAutoYieldings(routes);
    }

    function getAutoYieldings(address[] calldata assetAddresses) external view returns (address[] memory protocols) {
        return _assetManager.getAutoYieldings(assetAddresses);
    }

    function setAssetManager(address assetManager, uint64 expiresAt) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.setAssetManager(_vault, assetManager, expiresAt);
        emit AssetManagerSet(assetManager, expiresAt);
    }

    function getAssetManagerSettings()
        external
        view
        returns (address assetManager, uint64 expiresAt, address pendingAssetManager, uint64 pendingAt)
    {
        (address granted, uint64 grantedExpiresAt) = _assetManager.liveGrant();
        return (granted, grantedExpiresAt, _assetManager.pendingAssetManager, _assetManager.pendingAssetManagerAt);
    }

    function updatePayoutOperator(address payoutOperator, bool add) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (add && hasRole(DEFAULT_ADMIN_ROLE, payoutOperator)) revert OwnerAndPayoutOperatorMustDiffer();
        _vault.updatePayoutOperatorOne(payoutOperator, add);
        emit PayoutOperatorUpdated(payoutOperator, add);
    }

    function isAssetAllowed(address assetAddress) external view returns (bool) {
        return _vault.assetAllowed(assetAddress);
    }

    function isStableCoinAllowed(address assetAddress) external view returns (bool) {
        return _vault.stableCoinAllowed(assetAddress);
    }

    function isPayoutOperator(address account) external view returns (bool) {
        return _vault.isPayoutOperator(account);
    }

    function updateProtocols(address[] memory addProtocols, address[] memory removeProtocols)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.updateProtocols(addProtocols, removeProtocols);
        emit ProtocolsUpdated(addProtocols, removeProtocols);
    }

    function retrieve721(address contractAddress, uint256 tokenId, address to)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (to == address(0)) revert AddressZero();
        _assetManager.checkNotProtocolNFT(contractAddress);
        IERC721(contractAddress).safeTransferFrom(address(this), to, tokenId);
        emit Retrieved721(contractAddress, tokenId, to);
    }

    function wethAddress() external view returns (address) {
        return _vault.weth;
    }
}
