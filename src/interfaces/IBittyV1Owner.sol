// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {AutoYield, IBittyV1Vault} from "./IBittyV1Vault.sol";

/**
 * @title IBittyV1Owner
 * @notice The owner-only vault surface: configuration, the locks, sub-account guardrails, payment
 *         creation, and the whitelisted-recipient payout. Implemented by {BittyV1Vault}. Reads and
 *         permissionless calls live in {IBittyV1Vault}; trading and yield in {IBittyV1DeFi}.
 */
interface IBittyV1Owner {
    /**
     * The whole risk surface, in three numbers. `type(uint256).max` in any means "leave it alone",
     * so the owner can set one without restating the others.
     *
     * Four numbers stood here: a protection window for new payees, a send cap, the period that cap
     * ran over, and a timelock on changing any of it. Owners only ever had two questions, and the
     * rest was one of them asked twice — a protection window and a change timelock are both "how
     * long do I get to notice", and with one cap over a fixed day there is nothing for a separate
     * period to vary.
     *
     * None of the three can be turned off. A timelock with no ceilings protects the configuration and
     * not the money: a leaked key would send or trade everything away at once, and the wait would
     * only delay changes nobody needs to make. So each is held between bounds, and one the owner has
     * never set reads as the loosest it may be — 1 day, and 10,000 for each allowance.
     *
     * `timelock` is the single wait in front of everything deferred: a new whitelisted recipient, the
     * removal of one the owner can already pay, an asset-manager grant, a handover of the
     * vault, and any loosening of these numbers. At least 1 day, at most 30.
     * `sendDailyAllowance` is the ceiling on what may leave through regular sends, in whole USD per
     * rolling day, from 1 to 10,000. Regular sends are held to stablecoins, the only assets that can be
     * metered without reading a price. More than this, and any other asset, leaves through a
     * whitelisted recipient — one the owner set up at least a timelock before.
     *
     * `marketTradeDailyLossAllowance` is the market-trade protection, from 1 to 10,000 whole USD per
     * rolling day. A trade is a way out of the vault too: a leaked key that sells into a pool it set
     * up itself takes value without sending anything. So every market trade, the owner's or an asset
     * manager's, is valued at oracle price (a stablecoin counts as a dollar), must come out within 5%
     * of what it gave up, and what it came out short — price impact and fees included — is charged
     * against this ceiling. Only assets with a price feed can be traded at market.
     * The two ceilings are kept apart so that trading never uses up what may be sent, and sending
     * never uses up what trades may lose.
     *
     * All three move under the ratchet: tightening applies at once, loosening waits out the timelock
     * in force when it was asked for.
     */
    struct RiskSettings {
        uint256 timelock;
        uint256 sendDailyAllowance;
        uint256 marketTradeDailyLossAllowance;
    }

    event WhitelistedRecipientSet(uint256 indexed id, address recipient);
    event WhitelistedRecipientsRemoved(uint256[] ids);
    event WhitelistedRecipientRemovalQueued(uint256 indexed id, uint64 effectiveAt);

    event AssetsUpdated(address[] addAssets, address[] removeAssets);
    event ProtocolsUpdated(address[] addProtocols, address[] removeProtocols);
    event RiskSettingsUpdated(RiskSettings riskSettings);
    event WhitelistedRecipientPaid(uint256 indexed id, address recipient, address asset, uint256 amount);
    event Retrieved721(address indexed contractAddress, uint256 indexed tokenId, address indexed to);
    event StableCoinAsGasSet(bool enabled, address[] assets, uint64 dailyLimit, uint64 maxFeePerOp);
    event ActivationFeePaid(address indexed asset, uint256 amount);
    event RelayerFeePaid(address indexed asset, uint256 amount, uint256 spentToday, uint256 remainingToday);

    event LockLevelSet(uint8 level, uint64 closedEpoch);

    event OwnershipTransferQueued(address indexed newOwner, uint64 readyAt);
    event OwnershipTransferCancelled(address indexed newOwner);

    /**
     * @notice Update the assets.
     * @param addAssets The assets to add.
     * @param removeAssets The assets to remove.
     */
    function updateAssets(address[] memory addAssets, address[] memory removeAssets) external;

    /**
     * @notice Update the protocols.
     * @param addProtocols The protocols to add.
     * @param removeProtocols The protocols to remove.
     */
    function updateProtocols(address[] memory addProtocols, address[] memory removeProtocols) external;

    /**
     * @notice Set the stablecoin-as-gas settings.
     * @param assets The assets to use for stablecoin-as-gas operations.
     * @param dailyLimit The daily limit for stablecoin-as-gas operations.
     * @param maxFeePerOp The maximum fee per operation for stablecoin-as-gas operations.
     */
    function setStableCoinAsGas(address[] calldata assets, uint64 dailyLimit, uint64 maxFeePerOp) external;

    /**
     * @notice Disable stablecoin-as-gas operations.
     */
    function disableStableCoinAsGas() external;

    /**
     * @notice Set the auto yieldings.
     * @param routes The auto yieldings to set.
     */
    function setAutoYieldings(AutoYield[] calldata routes) external;

    /**
     * @notice Set any of the vault's wait, its regular-send daily allowance and its market-trade daily
     *         loss allowance.
     * @dev Reverts {RiskTimelockTooShort} / {RiskTimelockTooLong} for a timelock outside 1 to 30 days,
     *      and {RiskAllowanceOutOfRange} for an allowance of 0 or above 10,000.
     * @param riskSettings The three numbers, with `type(uint256).max` in any to leave it alone.
     */
    function updateRisk(RiskSettings calldata riskSettings) external;

    /**
     * @notice Retrieve an ERC-721 token from the vault.
     * @param contractAddress The address of the ERC-721 contract.
     * @param tokenId The token ID to retrieve.
     * @param to The address to send the token to.
     */
    function retrieve721(address contractAddress, uint256 tokenId, address to) external;

    /**
     * @notice Send to a whitelisted recipient.
     * @param id The id of the whitelisted recipient.
     * @param asset The asset to send.
     * @param amount The amount to send.
     * @param withdrawProtocols The withdrawable protocols to use.
     * @param withdrawAmounts The amounts to withdraw from the withdrawable protocols.
     */
    function sendToWhitelistedRecipient(
        uint256 id,
        address asset,
        uint256 amount,
        address[] calldata withdrawProtocols,
        uint256[] calldata withdrawAmounts
    ) external;

    /**
     * @notice Set the auto yielding for an asset.
     * @param route The auto yielding route.
     */
    function setAutoYielding(AutoYield calldata route) external;
}
