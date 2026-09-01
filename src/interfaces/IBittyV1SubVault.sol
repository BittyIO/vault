// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error SubVaultNotFound();
error SubVaultImplNotRegistered();
error NotParentVault();
error NotSubOwner();
error SubOwnerExpired();
error SubOwnerExpiryInPast();
error SubOwnerDeadlineRequired();
error SubVaultClosedError();

/**
 * @title IBittyV1SubVault
 * @notice A sub vault's parent-facing admin surface plus the sub owner's voluntary return. The full
 *         DeFi surface is reached through the sub vault's fallback → shared {BittyV1VaultDeFiFacet} and
 *         is not part of this interface. A sub vault can only ever move assets back to its parent — it
 *         has no arbitrary-transfer function.
 */
interface IBittyV1SubVault {
    /**
     * @notice One-time init by the parent at deployment.
     * @param vault The parent main vault (immutable thereafter).
     * @param subOwner The delegate who operates the sub's DeFi.
     * @param allowlistEnabled Whether the guard-trust switch starts on.
     * @param expiresAt When the sub owner's grant lapses; 0 = never.
     */
    function initialize(address vault, address subOwner, bool allowlistEnabled, uint64 expiresAt) external;

    /**
     * @notice Parent-forced pull of `assets`/`amounts` back to the parent vault. Parent only.
     * @param assets The assets to recall.
     * @param amounts The amounts of each asset to recall.
     */
    function recall(address[] calldata assets, uint256[] calldata amounts) external;

    /**
     * @notice Return `assets`/`amounts` to the parent vault — the sub's only exit. The sub owner
     *         while their grant is live; anyone once it has lapsed.
     * @param assets The assets to return to the parent vault.
     * @param amounts The amounts of each asset to return to the parent vault.
     */
    function returnToVault(address[] calldata assets, uint256[] calldata amounts) external;

    /**
     * @notice Reassign the operating sub owner and their grant expiry. Parent only (1-step — the
     *         parent is the backstop).
     * @param newOwner The new sub owner.
     * @param expiresAt When the new sub owner's grant lapses; 0 = never.
     */
    function setSubOwner(address newOwner, uint64 expiresAt) external;

    /**
     * @notice Extend, shorten or lift (0) the sub owner's grant without reassigning it. Parent only.
     * @param expiresAt When the sub owner's grant lapses; 0 = never.
     */
    function setSubOwnerExpiry(uint64 expiresAt) external;

    /**
     * @notice End the sub owner's mandate at this instant. Parent only; used when closing the sub.
     */
    function expireSubOwnerNow() external;

    /**
     * @notice The owner's gasless on/off switch for this sub. Parent only.
     * @param enabled Whether gasless is enabled.
     */
    function setGaslessEnabled(bool enabled) external;

    /**
     * @notice The main vault.
     * @return The main vault.
     */
    function vault() external view returns (address);

    /**
     * @notice The current sub owner.
     * @return The current sub owner.
     */
    function subOwner() external view returns (address);

    /**
     * @notice When the sub owner's grant lapses; 0 = never.
     * @return When the sub owner's grant lapses; 0 = never.
     */
    function subOwnerExpiresAt() external view returns (uint64);
}
