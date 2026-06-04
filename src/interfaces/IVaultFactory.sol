// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error VaultAlreadyDeployed();

interface IVaultFactory {
    /**
     * @notice Initialize the factory.
     * @param vaultImplementation_ The address of the vault implementation.
     * @param guardAddress_ The address of the guard.
     * @param wethAddress_ The address of the weth.
     */
    function initialize(address vaultImplementation_, address guardAddress_, address wethAddress_) external;

    /**
     * @notice Deploy a vault owned by owner.
     * @param owner The address of the owner.
     * @param name The name of the vault, can not be address(0), better be a safe multi-sig address.
     * @param assetManager The address of the asset manager (hot wallet / AI agent).
     * @param assetAddresses The addresses of the assets.
     * @param stableCoinAddresses The addresses of the stable coins.
     * @param lendingProtocols The addresses of the lending protocols.
     * @param stakingProtocols The addresses of the staking protocols.
     * @param ammProtocols The addresses of the amm protocols.
     * @return vault The address of the deployed vault.
     */
    function deployVault(
        address owner,
        string memory name,
        address assetManager,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols
    ) external returns (address vault);

    /**
     * @notice Predict the vault address for a given (owner, name) pair.
     * @param owner The address of the owner.
     * @param name The name of the vault.
     * @return vault The address of the vault.
     */
    function computeVaultAddress(address owner, string memory name) external view returns (address);
}
