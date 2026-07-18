// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

error VaultAlreadyActivated();
error NotDeployer();
error EthTransferFailed();

interface IBittyV1VaultFactory {
    /**
     * @notice An asset to pull from the caller into the freshly activated vault. When `usePermit` is
     *         true, the signed EIP-2612 permit (deadline/v/r/s) is consumed first so no separate
     *         approve transaction is needed; when false, the caller must have approved the factory
     *         beforehand (for tokens that do not support EIP-2612, e.g. WETH/WBTC) and the permit
     *         fields are ignored.
     */
    struct AssetInput {
        address asset;
        uint256 amount;
        bool usePermit;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /**
     * @notice Initialize the factory.
     * @param vaultImplementation_ The address of the vault implementation.
     * @param defiFacet_ The address of the shared DeFi facet the vaults forward to.
     * @param guardAddress_ The address of the guard.
     * @param wethAddress_ The address of the weth.
     */
    function initialize(address vaultImplementation_, address defiFacet_, address guardAddress_, address wethAddress_)
        external;

    /**
     * @notice Activate a vault owned by the caller (msg.sender), selecting protocols and assets by configuration.
     * @param assetAddresses The addresses of the assets.
     * @param lendingProtocols The addresses of the lending protocols.
     * @param stakingProtocols The addresses of the staking protocols.
     * @param ammProtocols The addresses of the amm protocols.
     * @param intentProtocols The addresses of the intent protocols.
     */
    function activateVault(
        address[] memory assetAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols
    ) external;

    /**
     * @notice Activate the caller's vault and fund it in one transaction: for each deposit, pull
     *         `amount` of `asset` from the caller into the vault — consuming a signed EIP-2612 permit
     *         first when `usePermit` is set, otherwise relying on a prior approval for tokens that do
     *         not support permit — then forward any attached ETH (msg.value) which the vault
     *         auto-wraps to WETH.
     * @dev `assetAddresses` is the vault's asset configuration (guard-checked). Include WETH there
     *      when depositing ETH so the vault tracks the wrapped balance. Deposited assets need not
     *      appear in `assetAddresses`, but only configured assets are tracked/tradeable by the vault.
     * @param assetAddresses The guard-registered assets/stable coins to configure on the vault.
     * @param deposits The assets to pull into the vault (via permit or prior approval).
     * @param lendingProtocols The addresses of the lending protocols.
     * @param stakingProtocols The addresses of the staking protocols.
     * @param ammProtocols The addresses of the amm protocols.
     * @param intentProtocols The addresses of the intent protocols.
     */
    function activateVaultWithAssets(
        address[] memory assetAddresses,
        AssetInput[] memory deposits,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols
    ) external payable;

    /**
     * @notice Get the vault address for a given owner.
     * @param owner The address of the owner.
     * @return vault The address of the vault.
     */
    function vaultAddress(address owner) external view returns (address vault);
}
