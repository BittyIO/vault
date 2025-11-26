// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {ITrust} from "../src/interfaces/ITrust.sol";
import {IBeneficiary} from "../src/interfaces/IBeneficiary.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {
    AddressZero,
    AmountIsZero,
    BeneficiarySettingsNotSet,
    AmountPerWithdrawalIsZero,
    minimalWithdrawDurationLessThan1Day,
    BeneficiaryWithdrawalInLimitDays,
    EventNameIsEmpty,
    EventNameDuplicated,
    percentageMoreThan10K,
    EventTriggerError,
    EventNameNotFound,
    TimestampIsZero,
    TimestampDuplicated,
    LengthMismatch,
    TimestampNotFound,
    TimestampIsInTheFuture,
    InsufficientStablecoinBalance
} from "../src/interfaces/Errors.sol";

contract BittyVaultBeneficiaryTest is Test {
    BittyVault public bittyVault;
    WETH public mockWETH;
    MockERC20 public mockWBTC;
    MockERC20 public mockUSDT;
    MockERC20 public mockUSDC;
    address public beneficiary;
    address public eventInputAddress;
    IBeneficiary.BeneficiarySettings public beneficiarySettings;
    string[] public eventNames;
    IBeneficiary.TriggerEvent[] public triggerEvents;
    IBeneficiary.TimeEvent[] public timeEvents;
    uint256[] public timestamps;
    uint256[] public amounts;
    uint256 public withdrawMoney;
    uint256 public marriageMoney;
    address public whiteListAddress;

    function setUp() public {
        mockWETH = new WETH();
        mockUSDT = new MockERC20("USDT", "USDT", 6);
        mockUSDC = new MockERC20("USDC", "USDC", 6);
        mockWBTC = new MockERC20("WBTC", "WBTC", 8);
        bittyVault = new BittyVault();
        beneficiary = makeAddr("alice");
        eventInputAddress = makeAddr("anyone");
        address[] memory assetAddresses = new address[](2);
        assetAddresses[0] = address(mockWBTC);
        assetAddresses[1] = address(mockWETH);
        address[] memory stableCoinAddresses = new address[](2);
        stableCoinAddresses[0] = address(mockUSDT);
        stableCoinAddresses[1] = address(mockUSDC);
        address[] memory yieldProviders = new address[](0);
        address[] memory swapProviders = new address[](0);
        whiteListAddress = address(new WhiteList());
        bittyVault.initialize(
            address(this),
            address(mockWETH),
            whiteListAddress,
            assetAddresses,
            stableCoinAddresses,
            yieldProviders,
            swapProviders
        );
        bittyVault.setBeneficiary(beneficiary);
        withdrawMoney = 100 * 1e6;
        marriageMoney = 100000 * 10e6;
        beneficiarySettings =
            IBeneficiary.BeneficiarySettings({amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 30 days});
        eventNames = new string[](1);
        triggerEvents = new IBeneficiary.TriggerEvent[](1);
        timeEvents = new IBeneficiary.TimeEvent[](1);
        timestamps = new uint256[](1);
        amounts = new uint256[](1);
    }

    function test_GetMoneyFailedIfNotBeneficiary() public {
        vm.deal(address(bittyVault), 10 ether);
        vm.expectRevert("Only beneficiary");
        bittyVault.getMoney(address(mockUSDT), beneficiary);
    }

    function test_GetMoneyFailedIfNoBeneficiarySettings() public {
        vm.deal(address(bittyVault), 10 ether);
        vm.expectRevert(BeneficiarySettingsNotSet.selector);
        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDT), beneficiary);
    }

    function test_SetBeneficiarySettingFailedIfAmountPerWithdrawalIsZero() public {
        vm.expectRevert(AmountPerWithdrawalIsZero.selector);
        bittyVault.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({amountPerWithdrawal: 0, minimalWithdrawDuration: 30 days})
        );
    }

    function test_SetBeneficiarySettingFailedIfMinimalWithdrawDurationLessThan1Day() public {
        vm.expectRevert(minimalWithdrawDurationLessThan1Day.selector);
        bittyVault.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 23 hours})
        );
    }

    function test_GetMoneyFailedIfWithdrawalInDuration() public {
        vm.deal(address(bittyVault), 10 ether);
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        uint256 usdtAmount = beneficiarySettings.amountPerWithdrawal;
        deal(address(mockUSDT), address(bittyVault), usdtAmount);
        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDT), beneficiary);
        deal(address(mockUSDT), address(bittyVault), usdtAmount);
        vm.warp(block.timestamp + 29 days);
        vm.expectRevert(BeneficiaryWithdrawalInLimitDays.selector);
        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDT), beneficiary);
    }

    function test_AddTriggerEventsFailedIfEventNameIsEmpty() public {
        eventNames[0] = "";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        vm.expectRevert(EventNameIsEmpty.selector);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
    }

    function test_AddTriggerEventsFailedIfEventInputAddressIsZero() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: address(0), amount: marriageMoney, isPercentage: false});
        vm.expectRevert(AddressZero.selector);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
    }

    function test_AddTriggerEventsFailedIfAmountIsZero() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: 0, isPercentage: false});
        vm.expectRevert(AmountIsZero.selector);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
    }

    function test_AddTriggerEventsFailedIfpercentageIsMoreThan10K() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: 10001, isPercentage: true});
        vm.expectRevert(percentageMoreThan10K.selector);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
    }

    function test_AddTriggerEventsFailedIfEventNameDuplicated() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        vm.expectRevert(EventNameDuplicated.selector);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
    }

    function test_AddTriggerEventsFailedIfEventTriggerError() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        vm.expectRevert(EventTriggerError.selector);
        bittyVault.getMoneyFromEvent("Marriage", address(mockUSDT), beneficiary);
    }

    function test_RemoveTriggerEventsFailedIfIrrevocable() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        bittyVault.setToIrrevocable();
        vm.expectRevert("Only revocable");
        bittyVault.removeTriggerEvents(eventNames);
    }

    function test_RemoveTriggerEventsFailedIfEventNameIsEmpty() public {
        eventNames[0] = "";
        vm.expectRevert(EventNameIsEmpty.selector);
        bittyVault.removeTriggerEvents(eventNames);
    }

    function test_RemoveTriggerEventsFailedIfEventNameNotFound() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        string[] memory eventNamesNotFound = new string[](1);
        eventNamesNotFound[0] = "MarriageNotFound";
        vm.expectRevert(EventNameNotFound.selector);
        bittyVault.removeTriggerEvents(eventNamesNotFound);
    }

    function test_GetMoneyFromEventFailedIfEventNameIsEmpty() public {
        eventNames[0] = "";
        vm.expectRevert(EventNameIsEmpty.selector);
        bittyVault.getMoneyFromEvent("", address(mockUSDT), beneficiary);
    }

    function test_GetMoneyFromEventWithAmountSuccess() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        deal(address(mockUSDT), address(bittyVault), marriageMoney);
        vm.prank(eventInputAddress);
        bittyVault.getMoneyFromEvent("Marriage", address(mockUSDT), beneficiary);
        assertEq(mockUSDT.balanceOf(beneficiary), marriageMoney, "Beneficiary should receive 100000 USDT");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0, "Trust should have 0 USDT after transfer");
    }

    function test_GetMoneyFromEventWithpercentageSuccess() public {
        eventNames[0] = "Marriage";
        uint256 percentage = 1000;
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: percentage, isPercentage: true});
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        deal(address(mockUSDT), address(bittyVault), marriageMoney);
        vm.prank(eventInputAddress);
        bittyVault.getMoneyFromEvent("Marriage", address(mockUSDT), beneficiary);
        uint256 percentageMoney = marriageMoney * percentage / 10000;
        assertEq(mockUSDT.balanceOf(beneficiary), percentageMoney, "Beneficiary should receive 10000 USDT");
        assertEq(
            mockUSDT.balanceOf(address(bittyVault)),
            marriageMoney - percentageMoney,
            "Trust should have 0 USDT after transfer"
        );
    }

    function test_AddTriggerEventsFailedIfIrrevocableBySetting() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.setToIrrevocable();
        vm.expectRevert("Only revocable");
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
    }

    function test_AddTriggerEventsFailedIfIrrevocableByPing() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.setAutoIrrevocableAfterNoPing(1);
        vm.warp(block.timestamp + 2);
        vm.expectRevert("Only revocable");
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
    }

    function test_RemoveTriggerEventsSuccess() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        bittyVault.removeTriggerEvents(eventNames);
        vm.prank(beneficiary);
        vm.expectRevert(EventNameNotFound.selector);
        bittyVault.getMoneyFromEvent(eventNames[0], address(mockUSDT), beneficiary);
    }

    function test_AddTimeEventsFailedIfTimestampIsZero() public {
        timestamps[0] = 0;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        vm.expectRevert(TimestampIsZero.selector);
        bittyVault.addTimeEvents(timestamps, timeEvents);
    }

    function test_AddTimeEventsFailedIfAmountIsZero() public {
        timestamps[0] = block.timestamp;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: 0, isPercentage: false});
        vm.expectRevert(AmountIsZero.selector);
        bittyVault.addTimeEvents(timestamps, timeEvents);
    }

    function test_AddTimeEventsFailedIfEventNameDuplicated() public {
        timestamps[0] = block.timestamp;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        bittyVault.addTimeEvents(timestamps, timeEvents);
        vm.expectRevert(TimestampDuplicated.selector);
        bittyVault.addTimeEvents(timestamps, timeEvents);
    }

    function test_AddTimeEventsFailedIfEventNameLengthMismatch() public {
        timestamps[0] = block.timestamp;
        IBeneficiary.TimeEvent[] memory timeEventsMismatch = new IBeneficiary.TimeEvent[](2);
        timeEventsMismatch[0] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        timeEventsMismatch[1] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        vm.expectRevert(LengthMismatch.selector);
        bittyVault.addTimeEvents(timestamps, timeEventsMismatch);
    }

    function test_GetMoneyByTimestampFailedIfTimestampIsZero() public {
        timestamps[0] = 0;
        vm.expectRevert(TimestampIsZero.selector);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0], address(mockUSDT), beneficiary);
    }

    function test_GetMoneyByTimestampFailedIfTimestampNotFound() public {
        timestamps[0] = block.timestamp;
        vm.expectRevert(TimestampNotFound.selector);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0], address(mockUSDT), beneficiary);
    }

    function test_GetMoneyByTimestampFailedIfTimestampIsInTheFuture() public {
        timestamps[0] = block.timestamp + 1 days;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        bittyVault.addTimeEvents(timestamps, timeEvents);
        vm.expectRevert(TimestampIsInTheFuture.selector);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0], address(mockUSDT), beneficiary);
    }

    function test_GetMoneyFromTimeEventSuccessByAmount() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        timestamps[0] = block.timestamp;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        bittyVault.addTimeEvents(timestamps, timeEvents);
        deal(address(mockUSDT), address(bittyVault), marriageMoney);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0], address(mockUSDT), beneficiary);
        assertEq(mockUSDT.balanceOf(beneficiary), marriageMoney, "Beneficiary should receive 100000 USDT");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0, "Trust should have 0 USDT after transfer");
    }

    function test_GetMoneyFromTimeEventSuccessByPercentage() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        timestamps[0] = block.timestamp;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: 1000, isPercentage: true});
        bittyVault.addTimeEvents(timestamps, timeEvents);
        deal(address(mockUSDT), address(bittyVault), marriageMoney);
        deal(address(mockUSDC), address(bittyVault), marriageMoney);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0], address(mockUSDT), beneficiary);

        uint256 percentageMoney = marriageMoney * 1000 / 10000;
        assertEq(mockUSDT.balanceOf(beneficiary), percentageMoney, "Beneficiary should receive 10000 USDT");
        assertEq(mockUSDC.balanceOf(beneficiary), percentageMoney, "Beneficiary should receive 10000 USDC");
        assertEq(
            mockUSDT.balanceOf(address(bittyVault)),
            marriageMoney - percentageMoney,
            "Trust should have 0 USDT after transfer"
        );
        assertEq(
            mockUSDC.balanceOf(address(bittyVault)),
            marriageMoney - percentageMoney,
            "Trust should have 0 USDC after transfer"
        );
    }

    function test_GetUSDTSuccessFromTrustFor100USD() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);

        uint256 usdtAmount = beneficiarySettings.amountPerWithdrawal;
        deal(address(mockUSDT), address(bittyVault), usdtAmount);

        assertEq(mockUSDT.balanceOf(address(bittyVault)), usdtAmount, "Trust should have 100 USDT");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDT");

        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDT), beneficiary);

        assertEq(mockUSDT.balanceOf(beneficiary), usdtAmount, "Beneficiary should receive 100 USDT");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0, "Trust should have 0 USDT after transfer");

        assertEq(bittyVault.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }

    function test_GetUSDTFailedIfUSDTInsufficient() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);

        uint256 tokenAmount = beneficiarySettings.amountPerWithdrawal;
        uint256 partialUSDT = beneficiarySettings.amountPerWithdrawal / 2;
        deal(address(mockUSDT), address(bittyVault), partialUSDT);
        deal(address(mockUSDC), address(bittyVault), tokenAmount);

        assertEq(mockUSDT.balanceOf(address(bittyVault)), partialUSDT, "Trust should have 50 USDT");
        assertEq(mockUSDC.balanceOf(address(bittyVault)), tokenAmount, "Trust should have 100 USDC");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDT");
        assertEq(mockUSDC.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDC");

        vm.prank(beneficiary);
        vm.expectRevert(InsufficientStablecoinBalance.selector);
        bittyVault.getMoney(address(mockUSDT), beneficiary);
    }

    function test_GetMoneyFailedIfBothUSDTAndUSDCInsufficient() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);

        uint256 partialAmount = beneficiarySettings.amountPerWithdrawal / 2;
        deal(address(mockUSDT), address(bittyVault), partialAmount);
        deal(address(mockUSDC), address(bittyVault), partialAmount);

        vm.expectRevert(InsufficientStablecoinBalance.selector);
        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDT), beneficiary);
    }

    function test_GetUSDCFirstWhenWithdrawUSDTFirstIsFalse() public {
        bittyVault.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 1 days})
        );

        uint256 tokenAmount = beneficiarySettings.amountPerWithdrawal;
        deal(address(mockUSDT), address(bittyVault), tokenAmount);
        deal(address(mockUSDC), address(bittyVault), tokenAmount);

        assertEq(mockUSDT.balanceOf(address(bittyVault)), tokenAmount, "Trust should have 100 USDT");
        assertEq(mockUSDC.balanceOf(address(bittyVault)), tokenAmount, "Trust should have 100 USDC");

        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDC), beneficiary);

        assertEq(mockUSDC.balanceOf(beneficiary), tokenAmount, "Beneficiary should receive 100 USDC");
        assertEq(mockUSDC.balanceOf(address(bittyVault)), 0, "Trust should have 0 USDC after transfer");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should not receive USDT");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), tokenAmount, "Trust should still have 100 USDT");

        assertEq(bittyVault.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }

    function test_GetUSDTFirstWhenWithdrawUSDTFirstIsTrue() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);

        uint256 tokenAmount = beneficiarySettings.amountPerWithdrawal;
        deal(address(mockUSDT), address(bittyVault), tokenAmount);
        deal(address(mockUSDC), address(bittyVault), tokenAmount);

        assertEq(mockUSDT.balanceOf(address(bittyVault)), tokenAmount, "Trust should have 100 USDT");
        assertEq(mockUSDC.balanceOf(address(bittyVault)), tokenAmount, "Trust should have 100 USDC");

        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDT), beneficiary);

        assertEq(mockUSDT.balanceOf(beneficiary), tokenAmount, "Beneficiary should receive 100 USDT");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0, "Trust should have 0 USDT after transfer");
        assertEq(mockUSDC.balanceOf(beneficiary), 0, "Beneficiary should not receive USDC");
        assertEq(mockUSDC.balanceOf(address(bittyVault)), tokenAmount, "Trust should still have 100 USDC");

        assertEq(bittyVault.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }

    function test_GetUSDTFallbackWhenUSDCInsufficientAndWithdrawUSDTFirstIsFalse() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);

        uint256 tokenAmount = beneficiarySettings.amountPerWithdrawal;
        uint256 partialUSDC = tokenAmount / 2;
        deal(address(mockUSDC), address(bittyVault), partialUSDC);
        deal(address(mockUSDT), address(bittyVault), tokenAmount);

        assertEq(mockUSDC.balanceOf(address(bittyVault)), partialUSDC, "Trust should have 50 USDC");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), tokenAmount, "Trust should have 100 USDT");
        assertEq(mockUSDC.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDC");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDT");

        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDT), beneficiary);

        assertEq(mockUSDT.balanceOf(beneficiary), tokenAmount, "Beneficiary should receive 100 USDT");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0, "Trust should have 0 USDT after transfer");
        assertEq(mockUSDC.balanceOf(beneficiary), 0, "Beneficiary should not receive USDC");
        assertEq(mockUSDC.balanceOf(address(bittyVault)), partialUSDC, "Trust should still have 50 USDC");

        assertEq(bittyVault.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }
}
