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
         * Since we only support USDT and USDC, the amount can be like 2000 * 10e6 (2000 USD) for both of them.
         */
        uint256 amountPerWithdrawal;
        /**
         * @dev The minimal days between withdrawals.
         * @param minimalWithdrawDuration The minimal timestamp between withdrawals.
         *
         * It can not be 0 for security, should > 1 day.
         */
        uint256 minimalWithdrawDuration;
        /**
         * @dev Whether to withdraw USDT first if the trust has enough USDT.
         * @param withdrawUSDTFirst Whether to withdraw USDT first if the trust has enough USDT.
         */
        bool withdrawUSDTFirst;
    }

    struct TriggerEvent {


        /**
         * @dev The address of the event trigger.
         * @param triggerAddress The address of the event trigger.
         */
        address triggerAddress;
        /**
         * @dev The amount or percentage(1 / 10000 as unit) of the money to release.
         * @param amount
         * The amount of the money to release if ispercentage is false.
         * The percentage of the money to release if ispercentage is true.
         */
        uint256 amount;

        /**
         * @dev whether the amount is the percentage of money distribute the money to the beneficiary.
         * @param isPesentage
         */
        bool isPercentage;
    }

    struct TimeEvent {


        /**
         * @dev The amount or percentage(1 / 10000 as unit) of the money to release.
         */
        uint256 amount;

        /**
         * @dev whether the amount is the percentage of money distribute the money to the beneficiary.
         * @param isPesentage
         */
        bool isPercentage;
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

    /**
     * @notice Get the money from the event.
     * @dev Get the money from the event.
     * @param eventName The name of the event.
     *
     * This is beneficiary only, if the beneficiary address is lost, no one can get money.
     */
    function getMoneyFromEvent(string memory eventName) external;

    /**
     * @notice Get the money from the time event.
     * @dev Get the money from the time event.
     * @param timestamp The timestamp of the event.
     *
     * This is beneficiary only, if the beneficiary address is lost, no one can get money.
     */
    function getMoneyByTimestamp(uint256 timestamp) external;
}
