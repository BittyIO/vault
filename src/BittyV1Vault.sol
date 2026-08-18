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
    RiskSettings,
    AutoYield
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

    // {autoYield} may only be invoked by the vault itself (from {receive}) or the owner-set trigger.
    error NotAutoYieldTrigger();

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
        _renounceOwner();
        emit OwnershipRenounced(formerOwner);
    }

    receive() external payable {
        address weth = _vault.weth;
        if (msg.value > 0 && weth != address(0) && msg.sender != weth) {
            WETH(payable(weth)).deposit{value: msg.value}();
            address[] memory one = new address[](1);
            one[0] = weth;
            try this.autoYield(one) {} catch {}
        }
    }

    /**
     * @notice Sweep the vault's spendable balance of each asset into its configured yield route.
     * @dev Never permissionless — a griefer could strand swap liquidity by routing on demand. The trigger
     *      check is done once for the whole batch.
     */
    function autoYield(address[] calldata assetAddresses) external {
        if (msg.sender != address(this) && msg.sender != _assetManager.autoYieldTrigger) {
            revert NotAutoYieldTrigger();
        }
        _assetManager.autoYield(assetAddresses);
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
        RiskSettings memory riskSettings,
        AutoYield[] memory autoYields,
        address autoYieldTrigger
    ) public initializer {
        _defiFacet = defiFacet;
        _vault.weth = weth;
        __AccessControl_init();
        _initOwner(owner);

        _vault.initialize(guardAddress, riskSettings);
        if (assetAddresses.length > 0) {
            _vault.addAssets(assetAddresses);
        }

        _assetManager.initialize(guardAddress);

        _assetManager.setAssetManager(owner);

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

        _assetManager.autoYieldTrigger = autoYieldTrigger;
        address[] memory autoYieldAssets = new address[](autoYields.length);
        for (uint256 i = 0; i < autoYields.length; i++) {
            _assetManager.registerAutoYield(_vault, autoYields[i]);
            autoYieldAssets[i] = autoYields[i].asset;
        }

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0 && weth != address(0)) {
            WETH(payable(weth)).deposit{value: ethBalance}();
        }

        // Route deposited (and just-wrapped) balances into their configured yield routes atomically.
        _assetManager.autoYield(autoYieldAssets);
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

    function send(
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
            _vault.proposeSend(recipients, assets, amounts);
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

    function reviewSends(uint256[] calldata approveIds, uint256[] calldata cancelIds)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _vault.reviewSends(approveIds, cancelIds);
    }

    function cancelSends(uint256[] calldata ids) external override onlyOwnerOrPayoutOperator {
        _vault.cancelSends(ids, _byOwner());
    }

    function addScheduledPayments(IBittyV1Vault.ScheduledPayment[] calldata scheduledPayments_)
        external
        override
        onlyOwnerOrPayoutOperator
        returns (uint256[] memory ids)
    {
        return _vault.addScheduledPayments(scheduledPayments_, _byOwner());
    }

    function updateScheduledPayments(
        uint256[] calldata ids,
        IBittyV1Vault.ScheduledPayment[] calldata scheduledPayments_
    ) external override onlyOwnerOrPayoutOperator {
        _vault.updateScheduledPayments(ids, scheduledPayments_, _byOwner());
    }

    function removeScheduledPayments(uint256[] calldata ids) external override onlyOwnerOrPayoutOperator {
        _vault.removeScheduledPayments(ids, _byOwner());
    }

    function reviewScheduledPayments(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.reviewScheduledPayments(approveIds, expectedHashes, cancelIds);
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
    function payScheduled(
        uint256[] calldata ids,
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) external {
        _pullScheduledFromPositions(ids, stakingProtocols, stakingAmounts, lendingProtocols, lendingAmounts);
        _vault.payScheduled(ids);
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
        _vault.payScheduledAmount(id, amount);
    }

    function addWhitelistedRecipients(address[] calldata recipients, address[] calldata allowedAssets)
        external
        override
        onlyOwnerOrPayoutOperator
        returns (uint256[] memory ids)
    {
        return _vault.addWhitelistedRecipients(recipients, allowedAssets, _byOwner());
    }

    function updateWhitelistedRecipients(
        uint256[] calldata ids,
        address[] calldata recipients,
        address[] calldata allowedAssets
    ) external override onlyOwnerOrPayoutOperator {
        _vault.updateWhitelistedRecipients(ids, recipients, allowedAssets, _byOwner());
    }

    function removeWhitelistedRecipients(uint256[] calldata ids) external override onlyOwnerOrPayoutOperator {
        _vault.removeWhitelistedRecipients(ids, _byOwner());
    }

    function reviewWhitelistedRecipients(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.reviewWhitelistedRecipients(approveIds, expectedHashes, cancelIds);
    }

    function sendToWhitelistedRecipients(
        uint256[] calldata ids,
        address[] calldata assets,
        uint256[] calldata amounts,
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Position sourcing must happen before payout (it uses the asset manager); the library validates the
        // ids/assets/amounts lengths, and _pullFromPositions validates the position arrays against assets.
        _pullFromPositions(assets, stakingProtocols, stakingAmounts, lendingProtocols, lendingAmounts);
        _vault.sendToWhitelistedRecipients(ids, assets, amounts);
    }

    function getWhitelistedRecipients(uint256[] calldata ids)
        external
        view
        returns (address[] memory recipients, address[] memory allowedAssets)
    {
        return _vault.getWhitelistedRecipients(ids);
    }

    function setMinimalBalances(address[] calldata assetAddresses, uint256[] calldata minimalBalances)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.setMinimalBalances(assetAddresses, minimalBalances);
        emit MinimalBalancesSet(assetAddresses, minimalBalances);
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

    function setAutoYieldTrigger(address trigger) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.autoYieldTrigger = trigger;
        emit AutoYieldTriggerSet(trigger);
    }

    function getAutoYieldTrigger() external view returns (address) {
        return _assetManager.autoYieldTrigger;
    }

    function setAssetManager(address assetManager) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetManager.setAssetManager(assetManager);
        emit AssetManagerSet(assetManager);
    }

    function getAssetManager() external view returns (address) {
        return _assetManager.assetManager;
    }

    function updatePayoutOperators(address[] calldata addPayoutOperators, address[] calldata removePayoutOperators)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        for (uint256 i; i < addPayoutOperators.length; ++i) {
            if (hasRole(DEFAULT_ADMIN_ROLE, addPayoutOperators[i])) revert OwnerAndPayoutOperatorMustDiffer();
        }
        _vault.updatePayoutOperators(addPayoutOperators, removePayoutOperators);
        emit PayoutOperatorsUpdated(addPayoutOperators, removePayoutOperators);
    }

    function getPayoutOperators() external view returns (address[] memory) {
        return _vault.getPayoutOperators();
    }

    function isPayoutOperator(address account) external view returns (bool) {
        return _vault.isPayoutOperator(account);
    }

    function updateLendingProtocols(address[] memory addLendingProtocols, address[] memory removeLendingProtocols)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addLendingProtocols(addLendingProtocols);
        _assetManager.removeLendingProtocols(removeLendingProtocols);
        emit LendingProtocolsUpdated(addLendingProtocols, removeLendingProtocols);
    }

    function updateStakingProtocols(address[] memory addStakingProtocols, address[] memory removeStakingProtocols)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addStakingProtocols(addStakingProtocols);
        _assetManager.removeStakingProtocols(removeStakingProtocols);
        emit StakingProtocolsUpdated(addStakingProtocols, removeStakingProtocols);
    }

    function updateAMMProtocols(address[] memory addAMMProtocols, address[] memory removeAMMProtocols)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addAMMProtocols(addAMMProtocols);
        _assetManager.removeAMMProtocols(removeAMMProtocols);
        emit AMMProtocolsUpdated(addAMMProtocols, removeAMMProtocols);
    }

    function updateIntentProtocols(address[] memory addIntentProtocols, address[] memory removeIntentProtocols)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _assetManager.addIntentProtocols(addIntentProtocols);
        _assetManager.removeIntentProtocols(removeIntentProtocols);
        emit IntentProtocolsUpdated(addIntentProtocols, removeIntentProtocols);
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
