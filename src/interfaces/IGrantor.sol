// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {ITrustee} from "./ITrustee.sol";
import {IBeneficiary} from "./IBeneficiary.sol";

/**
 * @title Create and set the rules of the Trust.
 * @dev
 */
interface IGrantor {
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
     * @param beneficiaryAddress The address of the beneficiary.
     */
    function initaialize(address grantorAddress, address beneficiaryAddress) external;

    /**
     * @notice Initialize the trust.
     * @dev Initialize the trust.
     * @param grantorAddress The address of the grantor.
     * @param beneficiaryAddress The address of the beneficiary.
     * @param trusteeAddress The address of the trustee.
     */
    function initialize(address grantorAddress, address beneficiaryAddress, address trusteeAddress) external;

    /**
     * @notice Set the grantor.
     * @dev Set the grantor.
     * @param grantorAddress The address of the grantor.
     */
    function setGrantor(address grantorAddress) external;

    /**
     * @notice Set the trustee.
     * @dev Set the trustee.
     * @param trusteeAddress The address of the trustee.
     */
    function setTrustee(address trusteeAddress) external;

    /**
     * @notice Set the beneficiary.
     * @dev Set the beneficiary.
     * @param beneficiaryAddress The address of the beneficiary.
     */
    function setBeneficiary(address beneficiaryAddress) external;

    /**
     * @notice Set the beneficiary settings.
     * @dev Set the trust rules.
     * @param beneficiarySettings The beneficiary settings.
     */
    function setBeneficiarySettings(IBeneficiary.BeneficiarySettings memory beneficiarySettings) external;

    /**
     * @notice Revoke the trust.
     * @dev Revoke the trust if the trust is revocable.
     * @param moneyWithdrawTo The address to withdraw the money.
     *
     * If the trust is not revocable, this function will revert.
     *
     * 1. If the subscription fee is not paid, make sure the subscription fee is paid in one transaction.
     */
    function revoke(address moneyWithdrawTo) external;

    /**
     * @notice Set the trust to irrevocable.
     * @dev Set the trust to irrevocable.
     */
    function setToIrrevocable() external;

    /**
     * @notice Set the start distribution timestamp of the trust.
     * @dev Set the start distribution timestamp of the trust.
     * @param startDistributionTimestamp The start distribution timestamp of the trust.
     */
    function setStartDistributionTimestamp(uint256 startDistributionTimestamp) external;

    /**
     * @notice Check if the distribution has started.
     * @dev Check if the distribution has started.
     * @return The status of the distribution.
     */
    function distributionStarted() external view returns (bool);

    /**
     * @notice Set the trust to irrevocable after no ping.
     * @dev Set the trust to irrevocable after no ping.
     * @param pingSeconds The number of seconds after no ping.
     */
    function setAutoIrrevocableAfterNoPing(uint256 pingSeconds) external;

    /**
     * @notice Ping the trust.
     * @dev Ping the trust to make sure the Grantor is still alive, works for setAutoIrrevocableAfterNoPing.
     */
    function ping() external;

    /**
     * @notice Upgrade the trust.
     * @dev Upgrade the trust to a new version of trust for free.
     * @param upgradeToContract The address of the upgrade to contract.
     */
    function upgrade(address upgradeToContract) external;
}
