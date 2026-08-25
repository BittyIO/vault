// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

interface IAssetManagerSettings {
    function getAssetManagerSettings()
        external
        view
        returns (address assetManager, uint64 expiresAt, address pendingAssetManager, uint64 pendingAt);
}

/**
 * @dev The live asset manager, derived the way {IBittyV1Vault-getAssetManagerSettings} callers must:
 *      a lapsed grant reads as address(0). Kept here so the expiry rule is written once.
 */
function effectiveAssetManager(address vault) view returns (address) {
    (address manager, uint64 expiresAt,,) = IAssetManagerSettings(vault).getAssetManagerSettings();
    return (expiresAt != 0 && expiresAt < block.timestamp) ? address(0) : manager;
}
