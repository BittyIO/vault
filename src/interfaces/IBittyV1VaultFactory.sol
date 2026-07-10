// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error VaultAlreadyDeployed();
error NotDeployer();

interface IBittyV1VaultFactory {
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
     * @return vault The address of the deployed vault.
     */
    function deployVault(address owner, string memory name) external returns (address vault);

    /**
     * @notice Deploy a vault owned by owner, user select protocols and assets.
     * @param owner The address of the owner.
     * @param name The name of the vault, can not be address(0), better be a safe multi-sig address.
     * @param assetManagers The addresses of the asset managers (hot wallet / AI agents).
     * @param assetAddresses The addresses of the assets.
     * @param lendingProtocols The addresses of the lending protocols.
     * @param stakingProtocols The addresses of the staking protocols.
     * @param ammProtocols The addresses of the amm protocols.
     * @param intentProtocols The addresses of the intent protocols.
     * @return vault The address of the deployed vault.
     */
    function deployVaultWithSelected(
        address owner,
        string memory name,
        address[] memory assetManagers,
        address[] memory assetAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols
    ) external returns (address vault);

    /**
     * @notice Deploy a vault owned by owner, user select all assets and protocols.
     * @param owner The address of the owner.
     * @param name The name of the vault, can not be address(0), better be a safe multi-sig address.
     * @param assetManagers The addresses of the asset managers (hot wallet / AI agents).
     * @return vault The address of the deployed vault.
     */
    function deployVaultAllSelected(address owner, string memory name, address[] memory assetManagers)
        external
        returns (address vault);

    /**
     * @notice Predict the vault address for a given (owner, name) pair.
     * @param owner The address of the owner.
     * @param name The name of the vault.
     * @return vault The address of the vault.
     */
    function computeVaultAddress(address owner, string memory name) external view returns (address);
}
