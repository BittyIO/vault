// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error VaultAlreadyActivated();
error InvalidActivationSignature();
error NotDeployer();

interface IBittyV1VaultFactory {
    /**
     * @notice Activate your own vault, paying its gas yourself.
     *
     * @dev Activate the vault by ETH as gas from the owner.
     *      Any native ETH in the vault will be wrapped into WETH.
     * @param allowlistEnabled Whether the vault starts restricted to its own allowlist. ON is the
     *        cautious default; OFF leaves the guard's catalog as the only gate. Reversible either
     *        way, and it does not affect the vault's address.
     * @param calls The owner's first operations, ABI-encoded calls on the vault, run as the owner in
     *        this same transaction once the vault is initialised. Empty activates and nothing more.
     */
    function activateVault(bool allowlistEnabled, bytes[] calldata calls) external;

    /**
     * @notice Activate a vault whose owner pays in stable coin rather than ETH: you supply the gas on
     *         their signed authority, and the vault repays you from the stable coin already in it.
     *
     * @dev The only path by which an owner holding no ETH can obtain a vault.
     * @param owner The address of the owner.
     * @param asset The address of the assset.
     * @param amount The amount of asset to pay for the activation.
     * @param allowlistEnabled Whether the vault starts restricted to its own allowlist. Part of what
     *        the owner SIGNS, not merely of what the submitter passes: whoever relays the activation
     *        must not get to choose the security posture of someone else's vault.
     * @param calls The owner's first operations, run as the owner once the vault is initialised. Signed
     *        along with everything else, so the relayer cannot add entries of its own.
     * @param signature The signature of the owner over (owner, asset, amount, allowlistEnabled, calls).
     */
    function activateVaultByAsset(
        address owner,
        address asset,
        uint256 amount,
        bool allowlistEnabled,
        bytes[] calldata calls,
        bytes calldata signature
    ) external;

    /**
     * @notice Get the vault address for a given owner.
     * @param owner The address of the owner.
     * @return vault The address of the vault.
     */
    function vaultAddress(address owner) external view returns (address vault);
}
