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

    struct TriggerEvent {


        /**
         * @dev The address of the event trigger.
         * @param triggerAddress The address of the event trigger.
         */
        address triggerAddress;
        /**
         * @dev The amount of the money to release.
         * @param amount The amount of the money to release.
         */
        uint256 amount;
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
     * @notice Add the money to the beneficiary from the event.
     * @dev Add the money to the beneficiary from the event.
     * @param eventNames The names of the events.
     * @param triggerEvents The trigger events.
     *
     * This is not working anymore if the trust is irrevocable.
     */
    function addTriggerEvents(string[] memory eventNames, IBeneficiary.TriggerEvent[] memory triggerEvents) external;

    /**
     * @notice Remove the release event.
     * @dev Remove the release event.
     * @param eventNames The names of the events.
     *
     * This is not working anymore if the trust is irrevocable.
     */
    function removeTriggerEvents(string[] memory eventNames) external;

    /**
     * @notice Add the time events.
     * @dev Add the time events.
     * @param timestamps The timestamps of the events.
     * @param amounts The amounts of the money to release.
     *
     * This is not working anymore if the trust is irrevocable.
     */
    function addTimeEvents(uint256[] memory timestamps, uint256[] memory amounts) external;

    /**
     * @notice Remove the time events.
     * @dev Remove the time events.
     * @param timestamps The timestamps of the events.
     *
     * This is not working anymore if the trust is irrevocable.
     */
    function removeTimeEvents(uint256[] memory timestamps) external;

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
