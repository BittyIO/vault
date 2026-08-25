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
import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
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
    using EnumerableSet for EnumerableSet.AddressSet;

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

    /**
     * @notice Sweep the vault's spendable balance of each asset into its configured yield route.
     * @dev Never permissionless — a griefer could strand swap liquidity by routing on demand. The trigger
     *      check is done once for the whole batch.
     */
    function autoYield(address assetAddress) external {
        _checkAutoYieldCaller();
        _assetManager.autoYieldOne(assetAddress);
    }

    function autoYields(address[] calldata assetAddresses) external {
        _checkAutoYieldCaller();
        _assetManager.autoYield(assetAddresses);
    }

    /**
     * @notice Reimburse the trusted forwarder, in stablecoin, for gas it fronted for this vault.
     * @dev Deliberately outside the payment-risk controls — see {VaultLogic-payRelayerFee}.
     */
    function payRelayerFee(address stableCoinAddress, uint256 amount) external {
        address forwarder = trustedForwarder();
        if (forwarder == address(0) || msg.sender != forwarder) revert NotTrustedForwarder();
        _vault.payRelayerFee(stableCoinAddress, amount);
    }

    /**
     * @notice What the forwarder may still reclaim from this vault today, as an 18-decimal
     *         whole-stable-coin-token value. Resets at 00:00 UTC.
     * @dev Read before relaying: going over reverts the whole relayed call, so the relayer would burn
     *      the gas it just spent and collect nothing.
     */
    function gasBudgetRemaining() external view returns (uint256) {
        return _vault.gasBudgetRemaining();
    }

    /**
     * @inheritdoc IBittyV1Owner
     */
    function setGasless(address[] calldata stableCoins, uint64 dailyLimit, uint64 maxFeePerOp_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.setGasless(stableCoins, dailyLimit, maxFeePerOp_);
    }

    /**
     * @inheritdoc IBittyV1Owner
     */
    function disableGasless() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.disableGasless();
    }

    /**
     * @notice The terms on which this vault will pay for relayed gas.
     * @dev dailyLimit of 0 means relaying is off; {gasBudgetRemaining} is the separate live figure.
     */
    function gaslessConfig()
        external
        view
        returns (address[] memory stableCoins, uint256 dailyLimit, uint256 maxFeePerOp)
    {
        return (_vault.getGaslessStableCoins(), _vault.gasBudgetDailyLimit(), _vault.maxFeePerOpValue());
    }

    /**
     * @notice Wrap any native ETH the vault is holding into WETH.
     * @dev receive() auto-wraps incoming ETH, but ETH can still land as raw native ETH — a deposit to
     *      the counterfactual address before the vault had code, a protocol paying out with a 2300-gas
     *      stipend (too little for receive() to wrap), a force-send, or ETH sent with calldata. The
     *      vault's WETH-denominated accounting can't spend raw ETH, so this converts it. Permissionless —
     *      it only moves the vault's own ETH into its own WETH.
     */
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

    function initialize(address owner, address weth, address activationStableCoin, uint256 activationFee)
        public
        initializer
    {
        _vault.weth = weth;
        __AccessControl_init();
        _initOwner(owner);

        _vault.initialize();

        _vault.seedMinimalAllowList(weth);

        if (activationStableCoin != address(0) && activationFee != 0) {
            _vault.payActivationFee(activationStableCoin, activationFee);
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
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) external override onlyOwnerOrPayoutOperator {
        if (_byOwner()) {
            _pullFromPositions(assets, stakingProtocols, stakingAmounts, lendingProtocols, lendingAmounts);
            _vault.send(recipients, assets, amounts);
        } else {
            _vault.proposeSend(recipients, assets, amounts, _msgSender());
        }
    }

    /**
     * @dev Unstake / withdraw each row's `assets[i]` from its position into the vault before a send.
     *      No-op when all position arrays are empty; otherwise all four must equal `assets.length`.
     */
    function _pullFromPositions(
        address[] calldata assets,
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) private {
        if (
            stakingProtocols.length == 0 && stakingAmounts.length == 0 && lendingProtocols.length == 0
                && lendingAmounts.length == 0
        ) {
            return;
        }
        uint256 n = assets.length;
        if (
            stakingProtocols.length != n || stakingAmounts.length != n || lendingProtocols.length != n
                || lendingAmounts.length != n
        ) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i = 0; i < n; i++) {
            _pullOneFromPositions(
                assets[i], stakingProtocols[i], stakingAmounts[i], lendingProtocols[i], lendingAmounts[i]
            );
        }
    }

    /**
     * @dev `address(0)` protocol or `0` amount skips that leg.
     */
    function _pullOneFromPositions(
        address assetAddress,
        address stakingProtocol,
        uint256 stakingAmount,
        address lendingProtocol,
        uint256 lendingAmount
    ) private {
        address asset = _payoutAsset(assetAddress);
        if (stakingProtocol != address(0) && stakingAmount > 0) {
            _assetManager.unstake(stakingProtocol, asset, stakingAmount, address(this));
        }
        if (lendingProtocol != address(0) && lendingAmount > 0) {
            _assetManager.withdraw(lendingProtocol, asset, lendingAmount, address(this));
        }
    }

    /**
     * @dev ETH (address(0)) payments use WETH on yield-position sourcing paths.
     */
    function _payoutAsset(address assetAddress) private view returns (address) {
        return assetAddress == address(0) ? _vault.weth : assetAddress;
    }

    function send(
        address recipient,
        address asset,
        uint256 amount,
        address stakingProtocol,
        uint256 stakingAmount,
        address lendingProtocol,
        uint256 lendingAmount
    ) external onlyOwnerOrPayoutOperator {
        if (_byOwner()) {
            _pullOneFromPositions(asset, stakingProtocol, stakingAmount, lendingProtocol, lendingAmount);
            _vault.sendOne(recipient, asset, amount);
        } else {
            _vault.proposeSendOne(recipient, asset, amount, _msgSender());
        }
    }

    function sendToWhitelistedRecipient(
        uint256 id,
        address asset,
        uint256 amount,
        address stakingProtocol,
        uint256 stakingAmount,
        address lendingProtocol,
        uint256 lendingAmount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pullOneFromPositions(asset, stakingProtocol, stakingAmount, lendingProtocol, lendingAmount);
        _vault.sendToWhitelistedRecipientOne(id, asset, amount);
    }

    function payScheduled(
        uint256 id,
        address stakingProtocol,
        uint256 stakingAmount,
        address lendingProtocol,
        uint256 lendingAmount
    ) external {
        address asset = _vault.scheduledPaymentAsset(id);
        _pullOneFromPositions(asset, stakingProtocol, stakingAmount, lendingProtocol, lendingAmount);
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

    /**
     * @dev Three callers, for three reasons. The vault itself, so {receive} can sweep a deposit. Bitty's
     *      keeper, which is what makes Auto Earn automatic. And the owner, so a vault is never dependent
     *      on that keeper being up — it is their money moving into routes they already chose.
     *
     *      Raw msg.sender for the self-call: an identity question, not an authorisation one, so it must
     *      never resolve to a relayed signer. The other two are authorisation, hence {_msgSender}.
     */
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

    /**
     * @notice Pay each scheduled payment `ids[i]`, optionally sourcing each row's funds from yield positions
     *         first. For row `i`, `stakingAmounts[i]` of the payment's asset is unstaked from
     *         `stakingProtocols[i]` and `lendingAmounts[i]` withdrawn from `lendingProtocols[i]` into the
     *         vault before the batched payout runs (`address(0)` / `0` = skip that leg). The staking and
     *         lending pairs are independently optional: an empty pair skips that leg; a supplied pair must
     *         equal `ids.length`. Pass empty arrays for a plain vault-balance payout.
     */
    function payScheduleds(
        uint256[] calldata ids,
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) external {
        _pullScheduledFromPositions(ids, stakingProtocols, stakingAmounts, lendingProtocols, lendingAmounts);
        _vault.payScheduled(ids, _msgSender());
    }

    /**
     * @dev Source each scheduled payment's funds from yield positions into the vault before paying. The
     *      staking and lending pairs are independently optional — an empty pair skips that leg entirely; a
     *      supplied pair must equal `ids.length`. Each row's asset is read from the scheduled payment config.
     */
    function _pullScheduledFromPositions(
        uint256[] calldata ids,
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) private {
        _pullScheduledLeg(ids, stakingProtocols, stakingAmounts, true);
        _pullScheduledLeg(ids, lendingProtocols, lendingAmounts, false);
    }

    function _pullScheduledLeg(
        uint256[] calldata ids,
        address[] calldata protocols,
        uint256[] calldata amounts,
        bool isStaking
    ) private {
        if (protocols.length == 0 && amounts.length == 0) {
            return;
        }
        uint256 n = ids.length;
        if (protocols.length != n || amounts.length != n) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i = 0; i < n; i++) {
            address asset = _vault.scheduledPaymentAsset(ids[i]);
            if (isStaking) {
                _pullOneFromPositions(asset, protocols[i], amounts[i], address(0), 0);
            } else {
                _pullOneFromPositions(asset, address(0), 0, protocols[i], amounts[i]);
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

    function getAutoYieldings(address[] calldata assetAddresses)
        external
        view
        returns (address[] memory protocols, bool[] memory isSupplyings)
    {
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

    function getPayoutOperators() external view returns (address[] memory) {
        return _vault.getPayoutOperators();
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

    function getAssets() external view returns (address[] memory) {
        return _vault.getAssets();
    }

    function getStableCoins() external view returns (address[] memory) {
        return _vault.getStableCoins();
    }
}
