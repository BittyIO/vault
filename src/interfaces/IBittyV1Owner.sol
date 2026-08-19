// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault, AutoYield} from "./IBittyV1Vault.sol";

/**
 * @title IBittyV1Owner
 * @notice The owner-only (DEFAULT_ADMIN_ROLE) vault surface: config, asset manager guardrails, payout operator
 *         guardrails, approval of payout operator proposals, and the whitelisted-recipient payout. Implemented
 *         by {BittyV1Vault}. Payment creation (callable by owner or payout operator) lives in
 *         {IBittyV1PayoutOperator}; reads/permissionless in {IBittyV1Vault}; asset manager trading/yield in
 *         {IBittyV1AssetManager}.
 */
interface IBittyV1Owner {
    /**
     * @notice Input to {updatePaymentRisk}: the payment-risk controls. Set a field to
     *         type(uint256).max ("UNCHANGED") to leave it as-is — those fields cost no storage access.
     *         Any other value is applied through the loosen-waits-changeTimelock guard.
     */
    struct PaymentRisk {
        uint256 newPaymentProtection;
        uint256 maxSendValue;
        uint256 maxSendInterval;
        uint256 changeTimelock;
    }

    event AssetsUpdated(address[] addAssets, address[] removeAssets);
    event AssetsLocked();
    event ProtocolsLocked();
    event LendingProtocolsUpdated(address[] addLendingProtocols, address[] removeLendingProtocols);
    event StakingProtocolsUpdated(address[] addStakingProtocols, address[] removeStakingProtocols);
    event AMMProtocolsUpdated(address[] addAMMProtocols, address[] removeAMMProtocols);
    event IntentProtocolsUpdated(address[] addIntentProtocols, address[] removeIntentProtocols);
    event MinimalBalancesSet(address[] assets, uint256[] minimalBalances);
    event AutoYieldTriggerSet(address indexed trigger);
    event AssetManagerSet(address indexed assetManager);
    event OwnershipRenounced(address indexed formerOwner);
    event PayoutOperatorsUpdated(address[] addPayoutOperators, address[] removePayoutOperators);
    event PaymentRiskUpdated(PaymentRisk paymentRisk);
    event WhitelistedRecipientsPaid(uint256[] ids, address[] recipients, address[] assets, uint256[] amounts);
    event ScheduledPaymentsApproved(uint256[] ids);
    event WhitelistedRecipientsApproved(uint256[] ids);
    event SendsApproved(uint256[] ids);
    event Retrieved721(address indexed contractAddress, uint256 indexed tokenId, address indexed to);

    /**
     * @notice Batch-set the assets. Adds are applied before removes.
     */
    function updateAssets(address[] memory addAssets, address[] memory removeAssets) external;

    /**
     * @notice Disable adding assets.
     */
    function disableAddingAssets() external;

    /**
     * @notice Disable adding protocols.
     */
    function disableAddingProtocols() external;

    /**
     * @notice The single renounce path. Instantly drops the admin role after
     *         verifying the caller's pre-committed rescue, leaving the vault
     *         permanently ownerless. No transfer delay, no cancel window. It
     *         clears nothing and loops over nothing, so an attacker holding the
     *         same key cannot grief it by inflating the scheduled-payment count.
     *         After renounce, payScheduled pays ONLY locked immutable payments,
     *         so every other entry (an attacker's injected mutable payment, or a
     *         whitelisted recipient — inert anyway, since sendToWhitelistedRecipient
     *         is owner-only) can never move funds.
     *
     * @param rescueScheduledPaymentId A locked immutable scheduled payment
     *        (immutable, approved, past its lock deadline, payments remaining) —
     *        the owner's pre-committed rescue that keeps paying its safe address
     *        in the ownerless vault. Reverts NoRescueTarget if it isn't one, so
     *        funds are never stranded.
     *
     *        It is passed in — rather than discovered on-chain — because the
     *        contract cannot cheaply find one itself, and this is the crux of the
     *        DoS-resistance:
     *        - Searching all payments for a locked immutable one is O(n) over an
     *          ever-growing id space (nextScheduledPaymentId only increments, even
     *          as entries are removed). That search is exactly the gas-griefing
     *          vector this design avoids: an attacker could add thousands of
     *          payments so the scan exceeds the block gas limit and bricks the
     *          renounce.
     *        - A cached counter can't replace the search either, because "locked"
     *          depends on block.timestamp >= effectiveAt, and crossing that
     *          deadline happens with the passage of time, not via any transaction —
     *          there is no moment at which to maintain the count. Counting merely
     *          immutable (not-yet-effective) payments would be unsafe: an
     *          attacker's immutable payment still inside its lock window would pass
     *          the check, then mature and drain to the attacker after renounce.
     *        So the owner names one witness and the contract verifies it in O(1).
     *
     *        It is only PROOF that a valid rescue exists — NOT a selector. After
     *        renounce, payScheduled pays EVERY locked immutable payment, not just
     *        this one, so a single id is sufficient regardless of how many the
     *        owner set up.
     */
    function renounceVaultOwnership(uint256 rescueScheduledPaymentId) external;

    /**
     * @notice Batch-set the lending protocols. Adds are applied before removes.
     */
    function updateLendingProtocols(address[] memory addLendingProtocols, address[] memory removeLendingProtocols)
        external;

    /**
     * @notice Batch-set the staking protocols. Adds are applied before removes.
     */
    function updateStakingProtocols(address[] memory addStakingProtocols, address[] memory removeStakingProtocols)
        external;

    /**
     * @notice Batch-set the AMM protocols. Adds are applied before removes.
     */
    function updateAMMProtocols(address[] memory addAMMProtocols, address[] memory removeAMMProtocols) external;

    /**
     * @notice Batch-set the intent protocols. Adds are applied before removes.
     */
    function updateIntentProtocols(address[] memory addIntentProtocols, address[] memory removeIntentProtocols) external;

    /**
     * @notice Batch-set the per-asset minimal balance (the liquid buffer kept out of
     *         auto-yield). One call for many assets; arrays must be equal length.
     */
    function setMinimalBalances(address[] calldata assetAddresses, uint256[] calldata minimalBalances) external;

    /**
     * @notice Batch-set the per-asset default yield routes AND the auto-yield trigger in one call, so
     *         turning Auto Earn on (routes + keeper) or off is a single transaction.
     * @dev One call for many assets; protocol = address(0) in a route clears that asset's route.
     *      `trigger` is ALWAYS written: the address (besides the vault itself) allowed to call
     *      {IBittyV1Vault.autoYield} on demand, on top of the vault's own deposit-time trigger
     *      (address(0) = none). Use a trusted keeper — the call moves funds into a yield position, so
     *      it must never be permissionless. A caller changing only routes must pass the current
     *      trigger (read via getAutoYieldTrigger); routes = [] changes only the trigger.
     */
    function setAutoYieldings(AutoYield[] calldata routes, address trigger) external;

    /**
     * @notice One-transaction setup for gasless (intent) trading: register the intent protocol, add the
     *         assets the vault must be allowed to receive, and pre-approve the settlement relayer for the
     *         tokens it will sell. Every step is skipped when already in place, so this is idempotent and
     *         safe to call before each order.
     * @dev Exists because a first trade otherwise costs up to THREE owner/manager transactions
     *      (updateIntentProtocols, updateAssets, approveIntentRelayer) before the gasless order can even
     *      be signed. Owner-gated: two of the three are owner powers, and the approval only lets the
     *      relayer pull tokens against an order the asset manager has signed and that
     *      {IBittyV1Vault.isOffchainOrderAuthorized} still accepts at settlement — so granting it moves
     *      no funds by itself.
     * @param intentProtocol The intent protocol (e.g. the CoW adapter) to register; address(0) skips.
     * @param assets Assets the vault must hold/receive — typically the order's buy token. Already-added
     *        entries are ignored; each must be registered on the Guard.
     * @param approveTokens Sell tokens to pre-approve for the protocol's settlement relayer.
     */
    function prepareIntentTrade(address intentProtocol, address[] calldata assets, address[] calldata approveTokens)
        external;

    /**
     * @notice Supply `amount` of `assetAddress` to `lendingProtocol`, registering the protocol first when
     *         the vault hasn't enabled it yet — the whole first-time lend in ONE transaction.
     * @dev Caller must be the owner (to register the protocol) AND the vault's asset manager (to move
     *      funds), i.e. the common single-user setup. A vault whose manager is a separate address keeps
     *      the two-step path: the owner calls {updateLendingProtocols}, the manager then supplies. The
     *      protocol registration is skipped when already present, so this stays usable after the owner
     *      has permanently locked adding protocols. Nothing else is needed: the protocol's token
     *      allowance is granted inside the supply itself, and lending needs no asset allow-listing.
     */
    function simpleSupply(address lendingProtocol, address assetAddress, uint256 amount) external;

    /**
     * @notice Stake `amount` of `assetAddress` into `stakingProtocol`, registering the protocol first when
     *         the vault hasn't enabled it yet — the whole first-time stake in ONE transaction.
     * @dev Same role requirement and semantics as {simpleSupply}.
     */
    function simpleStake(address stakingProtocol, address assetAddress, uint256 amount) external;

    /**
     * @notice Withdraw `amount` of `assetAddress` from `lendingProtocol` back into the vault, optionally
     *         clearing that asset's auto-yield route in the SAME transaction.
     * @dev Exiting a position that still has a route is otherwise two transactions — clear the route,
     *      then withdraw — because the keeper would sweep the funds straight back in between them.
     *      Caller must be the owner (to change the route) AND the vault's asset manager (to move funds),
     *      the same pairing as {simpleSupply}. Pass `clearRoute` = false to just withdraw.
     */
    function simpleWithdraw(address lendingProtocol, address assetAddress, uint256 amount, bool clearRoute) external;

    /**
     * @notice Unstake `amount` of `assetAddress` from `stakingProtocol` back into the vault, optionally
     *         clearing that asset's auto-yield route in the SAME transaction.
     * @dev Same role requirement and rationale as {simpleWithdraw}. `amount` = type(uint256).max drains
     *      the whole position (the adapter computes the exact fee-adjusted amount itself).
     */
    function simpleUnstake(address stakingProtocol, address assetAddress, uint256 amount, bool clearRoute) external;

    /**
     * @notice Set the vault's single asset manager, replacing any previous one. Only this address may trade;
     *         it has full trading access, bounded only by the token allowlist and per-asset minimal-balance
     *         floors. The owner may set itself.
     */
    function setAssetManager(address assetManager) external;

    /**
     * @notice Add and/or remove payout operators in one call (like {updateLendingProtocols}). Each added
     *         address must not already be registered and may not be the owner; each removed address must be
     *         registered. Adds are applied before removes.
     */
    function updatePayoutOperators(address[] calldata addPayoutOperators, address[] calldata removePayoutOperators)
        external;

    /**
     * @notice Owner: approve and/or cancel pending payout operator send proposals in one call (like
     *         {updatePayoutOperators}). approveIds are executed immediately; cancelIds are dropped. Approves
     *         are applied before cancels.
     */
    function reviewSends(uint256[] calldata approveIds, uint256[] calldata cancelIds) external;

    /**
     * @notice Owner: approve and/or reject payout operator scheduled-payment proposals in one call (like
     *         {reviewSends}). approveIds are approved — each expectedHashes[i] is
     *         keccak256(abi.encode(the ScheduledPayment the owner reviewed)) for approveIds[i], and a
     *         mismatch reverts so a proposer cannot swap content before approval — while cancelIds are
     *         removed. Approves run before cancels; approveIds/expectedHashes must be equal length.
     */
    function reviewScheduledPayments(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external;

    /**
     * @notice Owner: approve and/or reject payout operator whitelisted-recipient proposals in one call (like
     *         {reviewSends}). approveIds are approved — each expectedHashes[i] is
     *         keccak256(abi.encode(the WhitelistedRecipient the owner reviewed)) for approveIds[i], and a
     *         mismatch reverts so a proposer cannot swap content before approval — while cancelIds are
     *         removed. Approves run before cancels; approveIds/expectedHashes must be equal length.
     */
    function reviewWhitelistedRecipients(
        uint256[] calldata approveIds,
        bytes32[] calldata expectedHashes,
        uint256[] calldata cancelIds
    ) external;

    /**
     * @notice Update any subset of the payment-risk controls in one call. Fields set to the UNCHANGED
     *         sentinel (type(uint256).max) are left untouched (no storage access); the rest are applied
     *         through the loosen-waits-changeTimelock guard. Cheaper than separate setters when changing two
     *         or more, and never a blind copy — an in-flight (pending) timelocked change on an untouched
     *         field is preserved.
     */
    function updatePaymentRisk(PaymentRisk calldata update) external;

    /**
     * @notice Owner: pay one or more whitelisted recipients in a single call. ids/assets/amounts must be
     *         non-empty and equal length; row `i` pays `amounts[i]` of `assets[i]` to whitelisted recipient
     *         `ids[i]`.
     * @dev May first source the funds from yield positions: for row `i`, `stakingAmounts[i]` of `assets[i]`
     *      is unstaked from `stakingProtocols[i]` and `lendingAmounts[i]` withdrawn from `lendingProtocols[i]`
     *      into the vault before paying (`address(0)` / `0` = skip that leg). When any position array is
     *      non-empty all four must equal `assets.length`; pass empty arrays for a plain vault-balance payout.
     */
    function sendToWhitelistedRecipients(
        uint256[] calldata ids,
        address[] calldata assets,
        uint256[] calldata amounts,
        address[] calldata stakingProtocols,
        uint256[] calldata stakingAmounts,
        address[] calldata lendingProtocols,
        uint256[] calldata lendingAmounts
    ) external;

    /**
     * @notice Owner: rescue a stray ERC-721 that was transferred into the vault. The vault implements no
     *         onERC721Received, so safe transfers bounce — only plain transferFrom, unchecked mints and
     *         airdrops can strand an NFT here; this is the sole way back out.
     * @dev Two guards keep the rescue path from becoming a value exit that bypasses payment protections:
     *      - Reverts ProtocolNFT when `contractAddress` is the position NFT of any guard-registered AMM
     *        protocol (template or this vault's clone), so LP positions can never leave through it — even
     *        after the protocol is removed from the vault or deprecated in the guard.
     *      - Transfers via safeTransferFrom, never transferFrom: ERC-721 transferFrom shares its selector
     *        with ERC-20 transferFrom, so the plain variant would move `tokenId` worth of any ERC-20.
     *        ERC-20s do not implement safeTransferFrom, so they cannot be touched.
     *      NFT rescue is deliberately outside the payment-protection envelope (no delay, no caps): nothing
     *      of vault-accounted value can pass the guards above.
     * @param contractAddress The ERC-721 contract holding the stray token.
     * @param tokenId The token to retrieve.
     * @param to The address to send the token to.
     */
    function retrieve721(address contractAddress, uint256 tokenId, address to) external;
}
