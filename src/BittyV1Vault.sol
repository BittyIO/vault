// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1VaultBase} from "./BittyV1VaultBase.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {DeFiLogic} from "./logic/DeFiLogic.sol";
import {PaymentLogic} from "./logic/PaymentLogic.sol";
import {WhitelistLogic} from "./logic/WhitelistLogic.sol";
import {TokenAsGasLogic} from "./logic/TokenAsGasLogic.sol";
import {RiskLogic} from "./logic/RiskLogic.sol";
import {LockLib} from "./logic/LockLib.sol";
import {BittyStorage, VaultStorage} from "./logic/BittyStorage.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IBittyV1Owner} from "./interfaces/IBittyV1Owner.sol";
import {IBittyV1Forwarder} from "./interfaces/IBittyV1Forwarder.sol";
import {
    IBittyV1Vault,
    AddressZero,
    ArrayLengthMismatch,
    NotTrustedForwarder,
    InvalidRelayedCalldata,
    VaultLocked,
    NoPendingOwnershipTransfer,
    OwnershipNotRenounceable,
    PendingChanges,
    WhitelistEntryView
} from "./interfaces/IBittyV1Vault.sol";

/**
 * @title BittyV1Vault
 * @notice The main vault: owner payments + the owner's own DeFi (reached through fallback → shared
 *         {BittyV1VaultDeFiFacet}) + curated/timelocked/freezable UUPS upgrades (from
 *         {BittyV1VaultBase}). Payouts to arbitrary external addresses live only here and are
 *         owner-gated.
 */
contract BittyV1Vault is BittyV1VaultBase {
    address public immutable DEFI_FACET;

    constructor(address defiFacet) {
        DEFI_FACET = defiFacet;
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address gasWrapped_,
        bool restrictToOwnAllowList,
        address activationAsset,
        uint256 activationAmount,
        bytes[] calldata calls
    ) external initializer {
        if (owner_ == address(0) || gasWrapped_ == address(0)) revert AddressZero();
        __Ownable_init(owner_);
        PaymentLogic.initialize(gasWrapped_, restrictToOwnAllowList);
        uint256 bal = address(this).balance;
        if (bal > 0) WETH(payable(gasWrapped_)).deposit{value: bal}();
        if (activationAsset != address(0) && activationAmount != 0) {
            TokenAsGasLogic.payActivationFee(activationAsset, activationAmount);
        }
        if (restrictToOwnAllowList) {
            if (activationAsset != address(0)) {
                DeFiLogic.listInitialAsset(activationAsset);
            }
            DeFiLogic.listInitialAsset(gasWrapped_);
        }
        if (calls.length != 0) _runAsOwner(owner_, calls);
    }

    modifier notLocked() {
        LockLib.requireNotLocked();
        _;
    }

    function lockLevel() external view returns (uint8) {
        return LockLib.level();
    }

    function emergencyLock() external onlyOwner {
        _settleOwnership();
        LockLib.emergencyLock();
    }

    function unlock() external onlyOwner {
        LockLib.unlock();
    }

    function foreverLock(uint256 escapeRecipientId) external onlyOwner {
        _settleOwnership();
        WhitelistLogic.requireEscape(escapeRecipientId);
        LockLib.foreverLock();
    }

    function _gasWrapped() private view returns (address) {
        return BittyStorage.vault().gasWrapped;
    }

    function _payoutAsset(address asset) private view returns (address) {
        return asset == address(0) ? _gasWrapped() : asset;
    }

    function transferOwnership(address newOwner) public override onlyOwner notLocked {
        if (newOwner == address(0)) revert OwnershipNotRenounceable();
        _settleOwnership();
        VaultStorage storage $ = BittyStorage.vault();
        uint64 timelock = RiskLogic.riskTimelock();
        uint64 readyAt = uint64(block.timestamp) + timelock;
        $.ownershipReadyAt = uint40(readyAt);
        $.pendingOwner = newOwner;
        emit IBittyV1Owner.OwnershipTransferQueued(newOwner, readyAt);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        _settleOwnership();
        VaultStorage storage $ = BittyStorage.vault();
        if ($.ownershipReadyAt == 0) revert NoPendingOwnershipTransfer();
        address cancelled = $.pendingOwner;
        $.ownershipReadyAt = 0;
        $.pendingOwner = address(0);
        emit IBittyV1Owner.OwnershipTransferCancelled(cancelled);
    }

    function settleOwnershipTransfer() external {
        _settleOwnership();
    }

    function _settleOwnership() private {
        VaultStorage storage $ = BittyStorage.vault();
        uint256 readyAt = $.ownershipReadyAt;
        if (readyAt == 0 || block.timestamp < readyAt) return;
        address next = $.pendingOwner;
        $.ownershipReadyAt = 0; // same slot as `vaultOwner`, so the handover is one warm write
        $.pendingOwner = address(0);
        _transferOwnership(next);
    }

    function _pendingOwnershipTransfer() private view returns (address target, uint64 readyAt) {
        VaultStorage storage $ = BittyStorage.vault();
        readyAt = $.ownershipReadyAt;
        if (readyAt == 0 || block.timestamp >= readyAt) return (address(0), 0);
        return ($.pendingOwner, readyAt);
    }

    receive() external payable {
        address gasWrapped = _gasWrapped();
        if (msg.value > 0 && msg.sender != gasWrapped) {
            WETH(payable(gasWrapped)).deposit{value: msg.value}();
        }
    }

    function wrapNative() external {
        address gasWrapped = _gasWrapped();
        uint256 bal = address(this).balance;
        if (bal > 0 && gasWrapped != address(0)) WETH(payable(gasWrapped)).deposit{value: bal}();
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

    function batchSend(
        address recipient,
        address[] calldata assets,
        uint256[] calldata amounts,
        address[][] calldata withdrawProtocols,
        uint256[][] calldata withdrawAmounts
    ) external onlyOwner notLocked {
        _pullFromPositions(assets, withdrawProtocols, withdrawAmounts);
        PaymentLogic.batchSend(recipient, assets, amounts);
    }

    function send(
        address recipient,
        address asset,
        uint256 amount,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) external onlyOwner notLocked {
        _pullOneFromPositions(asset, withdrawProtocols, withdrawAmounts);
        PaymentLogic.send(recipient, asset, amount);
    }

    function addWhitelistedRecipient(address recipient) external onlyOwner notLocked returns (uint256) {
        return WhitelistLogic.addWhitelistedRecipientOne(recipient);
    }

    function sendAndAddWhitelistedRecipient(
        address recipient,
        address asset,
        uint256 amount,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) external onlyOwner notLocked returns (uint256) {
        _pullOneFromPositions(asset, withdrawProtocols, withdrawAmounts);
        PaymentLogic.send(recipient, asset, amount);
        return WhitelistLogic.addWhitelistedRecipientOne(recipient);
    }

    function batchSendAndAddWhitelistedRecipient(
        address recipient,
        address[] calldata assets,
        uint256[] calldata amounts,
        address[][] calldata withdrawProtocols,
        uint256[][] calldata withdrawAmounts
    ) external onlyOwner notLocked returns (uint256) {
        _pullFromPositions(assets, withdrawProtocols, withdrawAmounts);
        PaymentLogic.batchSend(recipient, assets, amounts);
        return WhitelistLogic.addWhitelistedRecipientOne(recipient);
    }

    function removeWhitelistedRecipients(uint256[] calldata ids) external onlyOwner notLocked {
        WhitelistLogic.removeWhitelistedRecipients(ids);
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

    function updateRisk(IBittyV1Owner.RiskSettings calldata settings) external onlyOwner notLocked {
        RiskLogic.updateRisk(settings);
    }

    function setTokenAsGas(address[] calldata assets, uint64 dailyLimit, uint64 maxFeePerOp)
        external
        onlyOwner
        notLocked
    {
        TokenAsGasLogic.setTokenAsGas(assets, dailyLimit, maxFeePerOp);
    }

    function disableTokenAsGas() external onlyOwner notLocked {
        TokenAsGasLogic.disableTokenAsGas();
    }

    function payRelayerFee(address asset, uint256 amount) external {
        if (msg.sender != trustedForwarder() || IBittyV1Forwarder(msg.sender).chargingVault() != address(this)) {
            revert NotTrustedForwarder();
        }
        if (LockLib.lockedForever()) revert VaultLocked();
        TokenAsGasLogic.payRelayerFee(asset, amount);
    }

    function retrieve721(address contractAddress, uint256 tokenId, address to) external onlyOwner notLocked {
        if (to == address(0)) revert AddressZero();
        IERC721(contractAddress).safeTransferFrom(address(this), to, tokenId);
        emit IBittyV1Owner.Retrieved721(contractAddress, tokenId, to);
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

    function pendingChanges() external view returns (PendingChanges memory p) {
        p = RiskLogic.pendingChanges();
        (p.newOwner, p.newOwnerReadyAt) = _pendingOwnershipTransfer();
        (p.newAssetManager, p.newAssetManagerAt, p.newAssetManagerPerms) = DeFiLogic._pendingAssetManagerGrant();
    }

    function riskSettings()
        external
        view
        returns (uint64 timelock, uint64 sendDailyAllowance, uint64 marketTradeDailyLossAllowance)
    {
        return RiskLogic.riskSettings();
    }

    function getWhitelistedRecipients(uint256[] calldata ids) external view returns (address[] memory recipients) {
        return WhitelistLogic.getWhitelistedRecipients(ids);
    }

    function getWhitelistedRecipientRemovals(uint256[] calldata ids) external view returns (uint64[] memory) {
        return WhitelistLogic.getWhitelistedRecipientRemovals(ids);
    }

    function getWhitelist(uint256 fromId, uint256 count)
        external
        view
        returns (uint256 lastId, WhitelistEntryView[] memory entries)
    {
        return WhitelistLogic.getWhitelist(fromId, count);
    }

    function tokenAsGasConfig()
        external
        view
        returns (address[] memory assets, uint256 dailyLimit, uint256 maxFeePerOp)
    {
        return (
            TokenAsGasLogic.getTokenAsGasAssets(),
            TokenAsGasLogic.gasBudgetDailyLimit(),
            TokenAsGasLogic.maxFeePerOpValue()
        );
    }

    function gasBudgetRemaining() external view returns (uint256) {
        if (LockLib.lockedForever()) return 0;
        return TokenAsGasLogic.gasBudgetRemaining();
    }

    function relayerFeeValue(address asset, uint256 amount) external view returns (uint256) {
        return TokenAsGasLogic.relayerFeeValue(asset, amount);
    }

    function isStableCoinAllowed(address asset) external view returns (bool) {
        return DeFiLogic.stableCoinAllowed(asset);
    }

    function gasWrappedAddress() external view returns (address) {
        return _gasWrapped();
    }
}
