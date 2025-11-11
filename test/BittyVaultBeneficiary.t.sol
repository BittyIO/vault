// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {ITrust} from "../src/interfaces/ITrust.sol";
import {IBeneficiary} from "../src/interfaces/IBeneficiary.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";

interface IWETH {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
}

contract MockWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract MockUSDT {
    mapping(address => uint256) public balanceOf;

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract MockUSDC {
    mapping(address => uint256) public balanceOf;

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract BittyVaultBeneficiaryTest is Test {
    BittyVault public bittyVault;
    MockWETH public mockWETH;
    MockUSDT public mockUSDT;
    MockUSDC public mockUSDC;
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

    function setUp() public {
        mockWETH = new MockWETH();
        mockUSDT = new MockUSDT();
        mockUSDC = new MockUSDC();
        bittyVault = new BittyVault();
        beneficiary = makeAddr("alice");
        eventInputAddress = makeAddr("anyone");
        bittyVault.initialize(
            address(this), address(mockWETH), address(0), address(mockUSDT), address(mockUSDC), address(0), address(0)
        );
        bittyVault.setBeneficiary(beneficiary);
        withdrawMoney = 100 * 1e6;
        marriageMoney = 100000 * 10e6;
        beneficiarySettings = IBeneficiary.BeneficiarySettings({
            amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 30 days, withdrawUSDTFirst: true
        });
        eventNames = new string[](1);
        triggerEvents = new IBeneficiary.TriggerEvent[](1);
        timeEvents = new IBeneficiary.TimeEvent[](1);
        timestamps = new uint256[](1);
        amounts = new uint256[](1);
    }

    function test_GetMoneyFailedIfNotBeneficiary() public {
        vm.deal(address(bittyVault), 10 ether);
        vm.expectRevert("Only beneficiary");
        bittyVault.getMoney();
    }

    function test_GetMoneyFailedIfNoBeneficiarySettings() public {
        vm.deal(address(bittyVault), 10 ether);
        vm.expectRevert(ITrust.BeneficiarySettingsNotSet.selector);
        vm.prank(beneficiary);
        bittyVault.getMoney();
    }

    function test_SetBeneficiarySettingFailedIfAmountPerWithdrawalIsZero() public {
        vm.expectRevert(ITrust.AmountPerWithdrawalIsZero.selector);
        bittyVault.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({
                amountPerWithdrawal: 0, minimalWithdrawDuration: 30 days, withdrawUSDTFirst: false
            })
        );
    }

    function test_SetBeneficiarySettingFailedIfMinimalWithdrawDurationLessThan1Day() public {
        vm.expectRevert(ITrust.minimalWithdrawDurationLessThan1Day.selector);
        bittyVault.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({
                amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 23 hours, withdrawUSDTFirst: false
            })
        );
    }

    function test_GetMoneyFailedIfWithdrawalInDuration() public {
        vm.deal(address(bittyVault), 10 ether);
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        uint256 usdtAmount = beneficiarySettings.amountPerWithdrawal;
        mockUSDT.mint(address(bittyVault), usdtAmount);
        vm.prank(beneficiary);
        bittyVault.getMoney();
        mockUSDT.mint(address(bittyVault), usdtAmount);
        vm.warp(block.timestamp + 29 days);
        vm.expectRevert(ITrust.BeneficiaryWithdrawalInLimitDays.selector);
        vm.prank(beneficiary);
        bittyVault.getMoney();
    }

    function test_AddTriggerEventsFailedIfEventNameIsEmpty() public {
        eventNames[0] = "";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        vm.expectRevert(ITrust.EventNameIsEmpty.selector);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
    }

    function test_AddTriggerEventsFailedIfEventInputAddressIsZero() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: address(0), amount: marriageMoney, isPercentage: false});
        vm.expectRevert(ITrust.AddressZero.selector);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
    }

    function test_AddTriggerEventsFailedIfAmountIsZero() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: 0, isPercentage: false});
        vm.expectRevert(ITrust.AmountIsZero.selector);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
    }

    function test_AddTriggerEventsFailedIfpercentageIsMoreThan10K() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: 10001, isPercentage: true});
        vm.expectRevert(ITrust.percentageMoreThan10K.selector);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
    }

    function test_AddTriggerEventsFailedIfEventNameDuplicated() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        vm.expectRevert(ITrust.EventNameDuplicated.selector);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
    }

    function test_AddTriggerEventsFailedIfEventTriggerError() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        vm.expectRevert(ITrust.EventTriggerError.selector);
        bittyVault.getMoneyFromEvent("Marriage");
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
        vm.expectRevert(ITrust.EventNameIsEmpty.selector);
        bittyVault.removeTriggerEvents(eventNames);
    }

    function test_RemoveTriggerEventsFailedIfEventNameNotFound() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        string[] memory eventNamesNotFound = new string[](1);
        eventNamesNotFound[0] = "MarriageNotFound";
        vm.expectRevert(ITrust.EventNameNotFound.selector);
        bittyVault.removeTriggerEvents(eventNamesNotFound);
    }

    function test_GetMoneyFromEventWithAmountSuccess() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        mockUSDT.mint(address(bittyVault), marriageMoney);
        vm.prank(eventInputAddress);
        bittyVault.getMoneyFromEvent("Marriage");
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
        mockUSDT.mint(address(bittyVault), marriageMoney);
        vm.prank(eventInputAddress);
        bittyVault.getMoneyFromEvent("Marriage");
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
        vm.expectRevert(ITrust.EventNameNotFound.selector);
        bittyVault.getMoneyFromEvent(eventNames[0]);
    }

    function test_AddTimeEventsFailedIfTimestampIsZero() public {
        timestamps[0] = 0;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        vm.expectRevert(ITrust.TimestampIsZero.selector);
        bittyVault.addTimeEvents(timestamps, timeEvents);
    }

    function test_AddTimeEventsFailedIfAmountIsZero() public {
        timestamps[0] = block.timestamp;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: 0, isPercentage: false});
        vm.expectRevert(ITrust.AmountIsZero.selector);
        bittyVault.addTimeEvents(timestamps, timeEvents);
    }

    function test_AddTimeEventsFailedIfEventNameDuplicated() public {
        timestamps[0] = block.timestamp;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        bittyVault.addTimeEvents(timestamps, timeEvents);
        vm.expectRevert(ITrust.TimestampDuplicated.selector);
        bittyVault.addTimeEvents(timestamps, timeEvents);
    }

    function test_AddTimeEventsFailedIfEventNameLengthMismatch() public {
        timestamps[0] = block.timestamp;
        IBeneficiary.TimeEvent[] memory timeEventsMismatch = new IBeneficiary.TimeEvent[](2);
        timeEventsMismatch[0] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        timeEventsMismatch[1] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        vm.expectRevert(ITrust.LengthMismatch.selector);
        bittyVault.addTimeEvents(timestamps, timeEventsMismatch);
    }

    function test_GetMoneyByTimestampFailedIfTimestampIsZero() public {
        timestamps[0] = 0;
        vm.expectRevert(ITrust.TimestampIsZero.selector);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0]);
    }

    function test_GetMoneyByTimestampFailedIfTimestampNotFound() public {
        timestamps[0] = block.timestamp;
        vm.expectRevert(ITrust.TimestampNotFound.selector);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0]);
    }

    function test_GetMoneyByTimestampFailedIfTimestampIsInTheFuture() public {
        timestamps[0] = block.timestamp + 1 days;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        bittyVault.addTimeEvents(timestamps, timeEvents);
        vm.expectRevert(ITrust.TimestampIsInTheFuture.selector);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0]);
    }

    function test_GetMoneyFromTimeEventSuccessByAmount() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        timestamps[0] = block.timestamp;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        bittyVault.addTimeEvents(timestamps, timeEvents);
        mockUSDT.mint(address(bittyVault), marriageMoney);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0]);
        assertEq(mockUSDT.balanceOf(beneficiary), marriageMoney, "Beneficiary should receive 100000 USDT");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0, "Trust should have 0 USDT after transfer");
    }

    function test_GetMoneyFromTimeEventSuccessByPercentage() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        timestamps[0] = block.timestamp;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: 1000, isPercentage: true});
        bittyVault.addTimeEvents(timestamps, timeEvents);
        mockUSDT.mint(address(bittyVault), marriageMoney);
        mockUSDC.mint(address(bittyVault), marriageMoney);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0]);

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
        mockUSDT.mint(address(bittyVault), usdtAmount);

        assertEq(mockUSDT.balanceOf(address(bittyVault)), usdtAmount, "Trust should have 100 USDT");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDT");

        vm.prank(beneficiary);
        bittyVault.getMoney();

        assertEq(mockUSDT.balanceOf(beneficiary), usdtAmount, "Beneficiary should receive 100 USDT");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0, "Trust should have 0 USDT after transfer");

        assertEq(bittyVault.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }

    function test_GetUSDCFallbackWhenUSDTInsufficient() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);

        uint256 tokenAmount = beneficiarySettings.amountPerWithdrawal;
        uint256 partialUSDT = beneficiarySettings.amountPerWithdrawal / 2;
        mockUSDT.mint(address(bittyVault), partialUSDT);
        mockUSDC.mint(address(bittyVault), tokenAmount);

        assertEq(mockUSDT.balanceOf(address(bittyVault)), partialUSDT, "Trust should have 50 USDT");
        assertEq(mockUSDC.balanceOf(address(bittyVault)), tokenAmount, "Trust should have 100 USDC");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDT");
        assertEq(mockUSDC.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDC");

        vm.prank(beneficiary);
        bittyVault.getMoney();

        assertEq(mockUSDC.balanceOf(beneficiary), tokenAmount, "Beneficiary should receive 100 USDC");
        assertEq(mockUSDC.balanceOf(address(bittyVault)), 0, "Trust should have 0 USDC after transfer");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should not receive USDT");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), partialUSDT, "Trust should still have 50 USDT");

        assertEq(bittyVault.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }

    function test_GetMoneyFailedIfBothUSDTAndUSDCInsufficient() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);

        uint256 partialAmount = beneficiarySettings.amountPerWithdrawal / 2;
        mockUSDT.mint(address(bittyVault), partialAmount);
        mockUSDC.mint(address(bittyVault), partialAmount);

        vm.expectRevert(ITrust.InsufficientStablecoinBalance.selector);
        vm.prank(beneficiary);
        bittyVault.getMoney();
    }

    function test_GetUSDCFirstWhenWithdrawUSDTFirstIsFalse() public {
        bittyVault.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({
                amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 1 days, withdrawUSDTFirst: false
            })
        );

        uint256 tokenAmount = beneficiarySettings.amountPerWithdrawal;
        mockUSDT.mint(address(bittyVault), tokenAmount);
        mockUSDC.mint(address(bittyVault), tokenAmount);

        assertEq(mockUSDT.balanceOf(address(bittyVault)), tokenAmount, "Trust should have 100 USDT");
        assertEq(mockUSDC.balanceOf(address(bittyVault)), tokenAmount, "Trust should have 100 USDC");

        vm.prank(beneficiary);
        bittyVault.getMoney();

        assertEq(mockUSDC.balanceOf(beneficiary), tokenAmount, "Beneficiary should receive 100 USDC");
        assertEq(mockUSDC.balanceOf(address(bittyVault)), 0, "Trust should have 0 USDC after transfer");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should not receive USDT");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), tokenAmount, "Trust should still have 100 USDT");

        assertEq(bittyVault.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }

    function test_GetUSDTFirstWhenWithdrawUSDTFirstIsTrue() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);

        uint256 tokenAmount = beneficiarySettings.amountPerWithdrawal;
        mockUSDT.mint(address(bittyVault), tokenAmount);
        mockUSDC.mint(address(bittyVault), tokenAmount);

        assertEq(mockUSDT.balanceOf(address(bittyVault)), tokenAmount, "Trust should have 100 USDT");
        assertEq(mockUSDC.balanceOf(address(bittyVault)), tokenAmount, "Trust should have 100 USDC");

        vm.prank(beneficiary);
        bittyVault.getMoney();

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
        mockUSDC.mint(address(bittyVault), partialUSDC);
        mockUSDT.mint(address(bittyVault), tokenAmount);

        assertEq(mockUSDC.balanceOf(address(bittyVault)), partialUSDC, "Trust should have 50 USDC");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), tokenAmount, "Trust should have 100 USDT");
        assertEq(mockUSDC.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDC");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDT");

        vm.prank(beneficiary);
        bittyVault.getMoney();

        assertEq(mockUSDT.balanceOf(beneficiary), tokenAmount, "Beneficiary should receive 100 USDT");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0, "Trust should have 0 USDT after transfer");
        assertEq(mockUSDC.balanceOf(beneficiary), 0, "Beneficiary should not receive USDC");
        assertEq(mockUSDC.balanceOf(address(bittyVault)), partialUSDC, "Trust should still have 50 USDC");

        assertEq(bittyVault.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }
}
