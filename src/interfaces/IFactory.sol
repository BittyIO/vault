// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

error VaultAlreadyDeployed();

/**
 * @title IFactory
 * @notice Interface for the factory.
 * @dev This interface is used to initialize the factory and deploy the vault.
 */
interface IFactory {
    /**
     * @notice Initialize the factory.
     * @param vaultImplementation_ The address of the vault implementation.
     * @param whiteListAddress_ The address of the white list.
     * @param wethAddress_ The address of the weth.
     * @dev Initialize the factory.
     */
    function initialize(address vaultImplementation_, address whiteListAddress_, address wethAddress_) external;

    /**
     * @notice Deploy the vault.
     * @param assetAddresses The addresses of the assets.
     * @param stableCoinAddresses The addresses of the stable coins.
     * @param lendingProviders The addresses of the lending providers.
     * @param stakingProviders The addresses of the staking providers.
     * @param swapProviders The addresses of the swap providers.
     */
    function deployVault(
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory swapProviders
    ) external returns (address vault);

    /**
     * @notice Compute the vault address.
     * @param owner The owner of the vault.
     * @return The address of the vault.
     */
    function computeVaultAddress(address owner) external view returns (address);
}
