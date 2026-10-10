// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1VaultBase} from "./BittyV1VaultBase.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {DeFiLogic} from "./logic/DeFiLogic.sol";
import {PaymentLogic} from "./logic/PaymentLogic.sol";
import {ScheduledPaymentLogic} from "./logic/ScheduledPaymentLogic.sol";
import {WhitelistLogic} from "./logic/WhitelistLogic.sol";
import {GaslessLogic} from "./logic/GaslessLogic.sol";
import {RiskLogic} from "./logic/RiskLogic.sol";
import {BittyStorage} from "./logic/BittyStorage.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IBittyV1Owner} from "./interfaces/IBittyV1Owner.sol";
import {IBittyV1Forwarder} from "./interfaces/IBittyV1Forwarder.sol";
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
 *         {BittyV1VaultDeFiFacet}) + curated/timelocked/freezable UUPS upgrades (from
 *         {BittyV1VaultBase}). Payouts to arbitrary external addresses live only here and are
 *         owner/payout-operator gated.
 * @dev Renamed to BittyV1Vault at cutover.
 */
contract BittyV1Vault is BittyV1VaultBase {
    address public immutable DEFI_FACET;

    constructor(address defiFacet) {
        DEFI_FACET = defiFacet;
        _disableInitializers();
    }

    /**
     * @dev `calls` are the owner's first operations, run here as the owner so activation and, say, the
     *      first deposit share one transaction. Ordered after the fee and the ETH wrap on purpose: a
     *      batch cannot spend the stable coin the relayer is owed, and any ETH the counterfactual
     *      address was funded with is already WETH by the time a call tries to use it.
     */
    function initialize(
        address owner_,
        address gasWrapped_,
        bool allowlistEnabled,
        address activationAsset,
        uint256 activationAmount,
        bytes[] calldata calls
    ) external initializer {
        if (owner_ == address(0) || gasWrapped_ == address(0)) revert AddressZero();
        __Ownable_init(owner_);
        PaymentLogic.initialize(gasWrapped_);
        DeFiLogic.initialize(allowlistEnabled);
        if (activationAsset != address(0) && activationAmount != 0) {
            GaslessLogic.payActivationFee(activationAsset, activationAmount);
        }
        if (allowlistEnabled) {
            if (activationAsset != address(0)) {
                DeFiLogic.listInitialAsset(activationAsset);
            }
            DeFiLogic.listInitialAsset(gasWrapped_);
        }
        uint256 bal = address(this).balance;
        if (bal > 0) WETH(payable(gasWrapped_)).deposit{value: bal}();
        if (calls.length != 0) _runAsOwner(owner_, calls);
    }

    modifier onlyOwnerOrPayoutOperator() {
        if (_msgSender() != owner() && !PaymentLogic.isPayoutOperator(_msgSender())) revert NotPayoutOperator();
        _;
    }

    function _byOwner() private view returns (bool) {
        return _msgSender() == owner();
    }

    function _gasWrapped() private view returns (address) {
        return BittyStorage.vault().gasWrapped;
    }

    function _payoutAsset(address asset) private view returns (address) {
        return asset == address(0) ? _gasWrapped() : asset;
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
        address gasWrapped = _gasWrapped();
        if (msg.value > 0 && msg.sender != gasWrapped) {
            WETH(payable(gasWrapped)).deposit{value: msg.value}();
            try IAutoYieldTrigger(address(this)).autoYield(gasWrapped) {} catch {}
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
        _settleScheduledPayout(id, recipient, asset, payoutToken, needed, have, allowPartial, count, withdrawProtocols);
    }

    function payScheduledAmount(uint256 id, uint256 amount, address[] calldata withdrawProtocols) external {
        (
            bool skipped,
            address recipient,
            address asset,
            address payoutToken,
            uint256 target,
            uint256 have,
            bool allowPartial,
            uint256 count
        ) = ScheduledPaymentLogic.accrueScheduledAmount(id, amount, _msgSender(), withdrawProtocols.length > 0);
        if (skipped) return;
        _settleScheduledPayout(id, recipient, asset, payoutToken, target, have, allowPartial, count, withdrawProtocols);
    }

    function _settleScheduledPayout(
        uint256 id,
        address recipient,
        address asset,
        address payoutToken,
        uint256 needed,
        uint256 have,
        bool allowPartial,
        uint256 count,
        address[] calldata withdrawProtocols
    ) private {
        bool native = asset == address(0);
        uint256 covered = have >= needed
            ? 0
            : _coverShortfall(withdrawProtocols, payoutToken, native ? address(this) : recipient, needed - have);

        uint256 raw = (have < needed ? have : needed) + covered;
        uint256 delivered = raw < needed ? raw : needed;
        if (delivered == 0 || (delivered < needed && !allowPartial)) revert InsufficientBalance();

        ScheduledPaymentLogic.payScheduledOut(asset, recipient, native ? delivered : (have < needed ? have : needed));
        emit IBittyV1Vault.ScheduledPaymentPaid(id, recipient, asset, delivered, count);
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

    /**
     * @dev The forwarder, AND only while it is settling a fee for this vault.
     *
     *      `msg.sender == trustedForwarder()` is true of every relayed call as well, which is the
     *      whole point of ERC-2771 — so on its own it authorised the charge from inside any relayed
     *      request that could reach this function. {multicall} self-delegatecalls each entry with
     *      `msg.sender` untouched, so `multicall([payRelayerFee(USDC, 10e6) x 10])`, signed by a key
     *      with no role anywhere, moved a day's budget to the fee collector — of every vault, every
     *      day, by default.
     *
     *      The second half asks the question that was actually meant: the forwarder opens a transient
     *      window around its own settlement step naming the vault it is about to charge (see
     *      {BittyV1VaultForwarder-_CHARGING_SLOT}), and nothing else can open it. Inside a relayed
     *      request the window is shut, so the charge is refused however it was reached and however
     *      deeply it was nested — including through paths nobody has thought of yet, which is what
     *      the selector guards cannot promise.
     *
     *      Requires a forwarder that has the window. The forwarder is upgradeable and must be
     *      upgraded FIRST: a vault on this code against an older forwarder has no `chargingVault` to
     *      call, so the staticcall returns nothing, this reverts, and the vault simply cannot be
     *      charged — safe, but gasless stops working for it. The other order is harmless.
     */
    function payRelayerFee(address asset, uint256 amount) external {
        if (msg.sender != trustedForwarder() || IBittyV1Forwarder(msg.sender).chargingVault() != address(this)) {
            revert NotTrustedForwarder();
        }
        GaslessLogic.payRelayerFee(asset, amount);
    }

    function retrieve721(address contractAddress, uint256 tokenId, address to) external onlyOwner {
        if (to == address(0)) revert AddressZero();
        DeFiLogic.checkNotProtocolNFT(contractAddress);
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

    /**
     * @dev Funds a payout shortfall from the caller-chosen list of the vault's OWN positions. Counts
     *      only what actually ARRIVES at the sink, never what an adapter reports, and refuses an entry
     *      that delivers nothing: an asynchronous exit (Lido's withdrawal queue) consumes the position,
     *      returns 0 and funds nothing in this call, so trusting the list would let any caller of a
     *      trigger-less payment unstake the owner's positions as a side effect — repeatably, one list
     *      entry at a time. Reverting instead unwinds the queue request opened in the same call, so a
     *      list naming an asynchronous protocol fails whole rather than succeeding with a side effect.
     */
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
            uint256 sinkBefore = IERC20(payoutToken).balanceOf(sink);
            DeFiLogic.withdraw(protocol, payoutToken, available < remaining ? available : remaining, sink);
            uint256 got = IERC20(payoutToken).balanceOf(sink) - sinkBefore;
            if (got == 0) revert InsufficientBalance();
            covered += got;
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

    function gasWrappedAddress() external view returns (address) {
        return _gasWrapped();
    }
}
