// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {IBittyV1AssetManager} from "../../src/interfaces/IBittyV1AssetManager.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";

/**
 * @dev Test-only combined view of a deployed vault: the reads/permissionless (IBittyV1Vault), the
 *      owner (IBittyV1Owner) and the asset-manager (IBittyV1AssetManager) surfaces — the latter
 *      reached via the vault's fallback — plus the facet's few non-interface getters. Lets tests call
 *      any function on the real vault address without per-call casts.
 */
interface IVaultFull is IBittyV1Vault, IBittyV1Owner, IBittyV1AssetManager {
    function getClone(address protocol) external view returns (address);
    function guard() external view returns (IBittyV1Guard);
    function wethAddress() external view returns (address);
    function minimalBalance(address asset) external view returns (uint256);
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);
}
