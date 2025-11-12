// SPDX-License-Identifier: CC0-1.0
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
     */
    function getBaseFee() external;

    /**
     * @notice Get the revenue fee.
     * @dev Get the revenue fee.
     */
    function getRevenueFee() external;
}
