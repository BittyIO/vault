// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @title IBittyV1Forwarder
 * @notice The one thing an account needs to ask its forwarder: are you charging me, right now, in
 *         this call?
 * @dev `payRelayerFee` moves the vault's gas budget and used to authorise on `msg.sender ==
 *      trustedForwarder()` alone. That is not the same question. The forwarder is the caller for
 *      every relayed user op too — a relayed call runs with the forwarder as `msg.sender` by
 *      design — so "the forwarder is calling" was true in a situation the charge was never meant
 *      for, and anything that could reach the account's own entry points through a relayed request
 *      could reach the charge: `multicall([payRelayerFee])`, signed by any key with no role
 *      anywhere, drained every vault's daily budget to the fee collector.
 *
 *      {chargingVault} answers the right question. The forwarder opens a transient window around
 *      its own settlement step naming the vault it is about to charge, and the account checks it:
 *      inside a relayed request the window is shut, so a charge smuggled into relayed calldata
 *      reverts however deeply it is nested and whatever new path finds its way there.
 */
interface IBittyV1Forwarder {
    /**
     * @notice The vault this forwarder is settling a fee for in this call, or the zero address.
     * @dev Transient: true only between the relayed work finishing and the charge returning. A read
     *      at any other moment, including from inside a relayed request, is zero.
     */
    function chargingVault() external view returns (address);
}
