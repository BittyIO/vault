// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {RiskSettings, AutoYield} from "./IBittyV1Vault.sol";

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
     * @notice Activate the caller's vault, fund it, and configure auto-yielding in one transaction: each
     *         deposit is pulled from the caller into the (pre-deploy) vault address — consuming a signed
     *         EIP-2612 permit first when `usePermit` is set, otherwise relying on a prior approval for
     *         tokens that do not support permit — then any attached ETH (msg.value) is forwarded. The
     *         vault, on initialize, wraps native ETH into WETH and sweeps each route's spendable balance
     *         into its configured yield route atomically.
     * @dev Deposits and ETH land at the counterfactual vault address before CREATE2 deploys over it, so
     *      initialize sees the funds. Each `autoYields` entry registers its asset (as a vault asset)
     *      and protocol (into the matching lending/staking set) if not already present, so those need not
     *      also appear in the explicit arrays; the vault's add functions guard-check them.
     * @param autoYields The default yield routes to configure (and route the initial deposit into).
     *        Each route's asset and protocol are auto-registered, so they need not be repeated in
     *        `assetAddresses` / `lendingProtocols` / `stakingProtocols`.
     * @param autoYieldTrigger The address (besides the vault) allowed to trigger auto-yield (0 = none).
     * @param deposits The assets to pull into the vault (via permit or prior approval).
     * @param assetAddresses Extra guard-registered assets/stable coins to configure. Assets already named
     *        in `autoYields` are registered automatically, so list here ONLY assets with no route.
     * @param lendingProtocols Extra lending protocols. A protocol used by a supplying route is registered
     *        automatically, so list here ONLY lending protocols not referenced in `autoYields`.
     * @param stakingProtocols Extra staking protocols. A protocol used by a staking route is registered
     *        automatically, so list here ONLY staking protocols not referenced in `autoYields`.
     * @param ammProtocols The addresses of the amm protocols.
     * @param intentProtocols The addresses of the intent protocols.
     * @param riskSettings The payment-risk controls to seed the vault with.
     */
    function activateVault(
        AutoYield[] memory autoYields,
        address autoYieldTrigger,
        AssetInput[] memory deposits,
        address[] memory assetAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols,
        RiskSettings memory riskSettings
    ) external payable;

    /**
     * @notice Get the vault address for a given owner.
     * @param owner The address of the owner.
     * @return vault The address of the vault.
     */
    function vaultAddress(address owner) external view returns (address vault);
}
