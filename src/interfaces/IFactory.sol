// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error VaultAlreadyDeployed();

interface IFactory {
    /**
     * @notice Initialize the factory.
     * @param vaultImplementation_ The address of the vault implementation.
     * @param whiteListAddress_ The address of the white list.
     * @param subscriptionAddress_ The address of the subscription.
     * @param wethAddress_ The address of the weth.
     */
    function initialize(
        address vaultImplementation_,
        address whiteListAddress_,
        address subscriptionAddress_,
        address wethAddress_
    ) external;

    /**
     * @notice Deploy a vault owned by `tx.origin` (convenience for single EOA deployers).
     */
    function deployVault(
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory ammProviders
    ) external returns (address vault);

    /**
     * @notice Deploy a vault with a specific owner (e.g. an existing Gnosis Safe).
     * @param owner Vault owner; also used as the CREATE2 salt (`keccak256(owner)`).
     */
    function deployVaultFor(
        address owner,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory ammProviders
    ) external returns (address vault);

    /// @notice Predict the vault address for a given owner (salt = `keccak256(owner)`).
    function computeVaultAddress(address owner) external view returns (address);
}
