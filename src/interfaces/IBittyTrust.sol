// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IFundManager} from "./IFundManager.sol";
import {ITrustManager} from "./ITrustManager.sol";

/**
 * @title Manage the Trust.
 * @dev 
 **/
interface IBittyTrust {

    /**
     * @notice Initialize the trust.
     * @dev Initialize the trust.
     * @param grantorAddress The address of the grantor.
     */
    function initialize(address grantorAddress) external;


    /**
     * @notice Initialize the trust.
     * @dev Initialize the trust.
     * @param grantorAddress The address of the grantor.
     * @param trustManagerAddress The address of the trust manager.
     */
    function initaialize(address grantorAddress, address trustManagerAddress) external;

    /**
     * @notice Initialize the trust.
     * @dev Initialize the trust.
     * @param grantorAddress The address of the grantor.
     * @param trustManagerAddress The address of the trust manager.
     * @param fundManagerAddress The address of the fund manager.
     */
    function initialize(address grantorAddress, address trustManagerAddress, address fundManagerAddress) external;

    /**
     * @notice Subscribe the trust.
     * @dev Subscribe the trust yearly, if not, all the functions are not working.
     * @param yearCount The year count to subscribe.
     * Subscription fee is 10000 USD per year.
     */
    function subscribe(uint256 yearCount) external;

    /**
     * @notice Destory the trust.
     * @dev Destory the trust.
     * @param moneyWithdrawTo The address to withdraw the money.
     * 1. If the subscription fee is not paid, make sure the subscription fee is paid in one transaction.
     * 2. Destory fee is 1% of the whole trust fund of each assets.
     */
    function destory(address moneyWithdrawTo) external;

    /**
     * @notice Upgrade the trust.
     * @dev Upgrade the trust to a new version of trust for free.
     * @param upgradeToContract The address of the upgrade to contract.
     */
    function upgrade(address upgradeToContract) external;

    /**
     * @notice Get the USD value of the trust.
     * @dev Get the USD value of the trust.
     * @return The USD value of the trust.
     */
    function usdValue() external view returns (uint256);

}