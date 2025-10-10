// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {ITrustee} from "./ITrustee.sol";

/**
 * @title Create and set the rules of the Trust.
 * @dev
 *
 */
interface IGrantor {
    struct BeneficiarySettings {
        uint256 maxWithdrawalAmount;
        uint256 minimalDaysBetweenWithdrawals;
        bool autoWithdrawl;
    }

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
     * @notice Initialize the trust.
     * @dev Initialize the trust.
     * @param grantorAddress The address of the grantor.
     * @param beneficiaryAddress The address of the beneficiary.
     * @param trusteeAddress The address of the trustee.
     * @param protectorAddress The address of the protector.
     */
    function initialize(
        address grantorAddress,
        address beneficiaryAddress,
        address trusteeAddress,
        address protectorAddress
    ) external;

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
     * @notice Set the protector.
     * @dev Set the protector.
     * @param protectorAddress The address of the protector.
     */
    function setProtector(address protectorAddress) external;

    /**
     * @notice Set the beneficiary settings.
     * @dev Set the trust rules.
     * @param beneficiarySettings The beneficiary settings.
     */
    function setBeneficiarySettings(BeneficiarySettings memory beneficiarySettings) external;

    /**
     * @notice Set the rebalance rules.
     * @dev Set the rebalance rules.
     * @param rebalanceLimit The rebalance limit.
     */
    function setRebalanceRules(ITrustee.RebalanceLimit memory rebalanceLimit) external;

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
