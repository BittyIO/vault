// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @title MockChargeWindow
 * @notice Stands in for the forwarder's charge window in unit tests that charge a vault directly.
 * @dev {BittyV1Vault-payRelayerFee} asks its forwarder whether it is mid-settlement for this vault
 *      (see {IBittyV1Forwarder}). A unit test about the BUDGET does not want a relayed request and a
 *      signature to get at it — it wants to call the charge and check the arithmetic — so it etches
 *      this at `BITTY_FORWARDER` and names the vault once in `setUp`.
 *
 *      The window being open for the whole test is the point: these tests are not about who may
 *      charge. That the window is SHUT during relayed calldata, which is what makes the charge
 *      unreachable from a relayed request, is tested where it belongs — against the real forwarder,
 *      in Forwarder.t.sol.
 *
 *      A plain public variable, so the storage write lands at the etched address and the getter has
 *      the signature the vault calls.
 */
contract MockChargeWindow {
    address public chargingVault;

    function setChargingVault(address vault) external {
        chargingVault = vault;
    }
}
