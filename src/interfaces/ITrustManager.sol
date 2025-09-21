// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

/**
 * @title Pay the beneficiary by rules.
 * @dev 
 **/
interface ITrustManager {

    struct TrustLimit {
        uint256 maxWithdrawalAmount;    
        uint256 minimalDaysBetweenWithdrawals;
        bool autoWithdrawl;
    }

    /**
     * @notice Set the trust manager.
     * @dev Set the trust manager.
     * @param trustManagerAddress The address of the trust manager.
     */
    function setTrustManager(address trustManagerAddress) external;

    /**
     * @notice Set the beneficiary.
     * @dev Set the beneficiary.
     * @param beneficiaryAddress The address of the beneficiary.
     */
    function setBeneficiary(address beneficiaryAddress) external;

    /**
     * @notice Withdraw the beneficiary.
     * @dev Withdraw the beneficiary.
     */
    function withdraw() external;

    /**
     * @notice Set the trust rules.
     * @dev Set the trust rules.
     * @param trustLimit The trust limit.
     */
    function setTrustRules(ITrustManager.TrustLimit memory trustLimit) external;

    
}