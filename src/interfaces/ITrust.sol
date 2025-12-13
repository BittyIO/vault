// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IGrantor} from "./IGrantor.sol";
import {IBeneficiary} from "./IBeneficiary.sol";
import {ITrustee} from "./ITrustee.sol";

/**
 * @title Create and set the rules of the Trust.
 * @dev
 *
 */
interface ITrust is IGrantor, IBeneficiary, ITrustee {
    /**
     * @notice Set the trust to irrevocable.
     * @dev Set the trust to irrevocable.
     * @return The status of the trust.
     */
    function revocable() external view returns (bool);

    /**
     * @notice Get the trustee base fee.
     * @dev Get the trustee base fee.
     * @param stableCoinAddress The address of the stablecoin to get the money.
     */
    function getBaseFee(address stableCoinAddress) external;

    /**
     * @notice Get the revenue fee.
     * @dev Get the revenue fee.
     * @param stableCoinAddress The address of the stablecoin to get the money.
     */
    function getRevenueFee(address stableCoinAddress) external;
}
