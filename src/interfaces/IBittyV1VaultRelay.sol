// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ERC2771Forwarder} from "openzeppelin-contracts/contracts/metatx/ERC2771Forwarder.sol";

interface IBittyV1VaultRelay {
    /**
     * @notice Returns the next nonce for `signer` and requests targeting `target`.
     */
    function nonceFor(address signer, address target) external view returns (uint64);

    /**
     * @notice Sets whether `relayer` is approved to submit fee-charging requests.
     */
    function setRelayerApproval(address relayer, bool approved) external;

    /**
     * @notice Unsupported. Use {executeBatchWithFee} to relay an atomic batch for one vault.
     */
    function executeBatch(ERC2771Forwarder.ForwardRequestData[] calldata requests, address payable refundReceiver)
        external
        payable;

    /**
     * @notice Relays a signed request and reclaims `fee` of `stableCoinAddress` from the target vault.
     * @param request The owner- or asset-manager-signed forward request.
     * @param stableCoinAddress A stablecoin registered on the target vault.
     * @param fee Amount to reclaim in `stableCoinAddress` units. 0 relays without charging.
     */
    function executeWithFee(
        ERC2771Forwarder.ForwardRequestData calldata request,
        address stableCoinAddress,
        uint256 fee
    ) external payable;

    /**
     * @notice Relays signed requests for one vault and charges a single fee for the batch.
     * @param requests Signed requests, all with `to` equal to `vault`.
     * @param vault The target vault, charged once for the whole batch.
     * @param stableCoinAddress A stablecoin the vault's owner listed for gas.
     * @param fee Total to reclaim for the batch. 0 relays without charging.
     */
    function executeBatchWithFee(
        ERC2771Forwarder.ForwardRequestData[] calldata requests,
        address vault,
        address stableCoinAddress,
        uint256 fee
    ) external;
}
