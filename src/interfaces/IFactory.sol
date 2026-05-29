// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error VaultAlreadyDeployed();
error InvalidThreshold();
error OwnersRequired();

interface IFactory {
    /**
     * @notice Initialize the factory.
     * @param vaultImplementation_ The address of the vault implementation.
     * @param whiteListAddress_ The address of the white list.
     * @param subscriptionAddress_ The address of the subscription.
     * @param wethAddress_ The address of the weth.
     * @param safeProxyFactory_ The address of the Gnosis SafeProxyFactory.
     * @param safeSingleton_ The address of the Gnosis Safe singleton (implementation).
     */
    function initialize(
        address vaultImplementation_,
        address whiteListAddress_,
        address subscriptionAddress_,
        address wethAddress_,
        address safeProxyFactory_,
        address safeSingleton_
    ) external;

    /**
     * @notice Deploy a vault owned by tx.origin (single EOA owner).
     */
    function deployVault(
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory ammProviders
    ) external returns (address vault);

    /**
     * @notice Create a Gnosis Safe multi-sig and deploy a vault owned by it.
     * @param owners Safe owner addresses (e.g. 3 addresses for a 2/3 Safe).
     * @param threshold Number of signatures required (e.g. 2 for a 2/3 Safe).
     * @param saltNonce Nonce for deterministic Safe address — caller chooses it.
     */
    function deployVaultMultiSig(
        address[] memory owners,
        uint256 threshold,
        uint256 saltNonce,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory ammProviders
    ) external returns (address safe, address vault);

    /// @notice Predict the vault address for a single-owner deployment (salt = msg.sender).
    function computeVaultAddress(address owner) external view returns (address);

    /// @notice Predict the vault address for a multi-sig deployment (salt = safeAddress).
    function computeVaultAddressMultiSig(address safe) external view returns (address);
}
