// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

/**
 * @title The beneficiary of the Trust.
 * @dev
 */
interface IBeneficiary {
    struct BeneficiarySettings {
        /**
         * @dev The amount of the money to get per withdrawal.
         * @param amountPerWithdrawal The amount of the money to get per withdrawal.
         *
         * This is USD value of the money to get per withdrawal, if the trust do not have enough stablecoin,
         * it will convert the assets to stablecoin with market price and withdraw to the beneficiary.
         *
         * Since we only support USDT and USDC, the unit is 10^6.
         */
        uint256 amountPerWithdrawal;
        /**
         * @dev The minimal days between withdrawals.
         * @param minimalDaysBetweenWithdrawals The minimal days between withdrawals.
         */
        uint256 minimalDaysBetweenWithdrawals;

        /**
         * @dev Whether to withdraw USDT first if the trust has enough USDT.
         * @param withdrawUSDTFirst Whether to withdraw USDT first if the trust has enough USDT.
         */
        bool withdrawUSDTFirst;
    }

    /**
     * @notice only works if beneficiary address is set.
     * @dev only works for beneficiary to change address.
     * @param newBeneficiaryAddress new beneficiary address
     */
    function changeBeneficiaryAddress(address newBeneficiaryAddress) external;

    /**
     * @notice Get the money from the trust.
     * @dev Get the money from the trust.
     */
    function getMoney() external;
}
