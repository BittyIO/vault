// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {IBeneficiary} from "../src/interfaces/IBeneficiary.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {MockYieldProvider} from "./mock/MockYieldProvider.sol";
import {IWhiteList} from "../src/interfaces/IWhiteList.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {Migrator} from "../src/Migrator.sol";
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
    InsufficientStablecoinBalance,
    ReplaceTrusteeFailed
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
    MockYieldProvider public mockYieldProvider1;
    MockYieldProvider public mockYieldProvider2;
    MockYieldProvider public mockYieldProvider3;
    address public migratorAddress;

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

        mockYieldProvider1 = new MockYieldProvider();
        mockYieldProvider2 = new MockYieldProvider();
        mockYieldProvider3 = new MockYieldProvider();

        vm.startPrank(tx.origin);
        address[] memory yieldProviderAddresses = new address[](3);
        yieldProviderAddresses[0] = address(mockYieldProvider1);
        yieldProviderAddresses[1] = address(mockYieldProvider2);
        yieldProviderAddresses[2] = address(mockYieldProvider3);
        IWhiteList(whiteListAddress).addYieldProviders(yieldProviderAddresses);
        vm.stopPrank();

        migratorAddress = address(new Migrator());
        bittyVault.initialize(
            address(this),
            address(mockWETH),
            whiteListAddress,
            migratorAddress,
            assetAddresses,
            stableCoinAddresses,
            yieldProviders,
            swapProviders
        );
        bittyVault.setBeneficiary(beneficiary);
        bittyVault.setTrustee(address(this));
        withdrawMoney = 100;
        marriageMoney = 100000;
        beneficiarySettings = IBeneficiary.BeneficiarySettings({
            amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 30 days, replaceTrusteeDuration: 0
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
        bittyVault.getMoney(address(mockUSDT));
    }

    function test_GetMoneyFailedIfNoBeneficiarySettings() public {
        vm.deal(address(bittyVault), 10 ether);
        vm.expectRevert(BeneficiarySettingsNotSet.selector);
        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDT));
    }

    function test_SetBeneficiarySettingFailedIfAmountPerWithdrawalIsZero() public {
        vm.expectRevert(AmountPerWithdrawalIsZero.selector);
        bittyVault.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({
                amountPerWithdrawal: 0, minimalWithdrawDuration: 30 days, replaceTrusteeDuration: 0
            })
        );
    }

    function test_SetBeneficiarySettingFailedIfMinimalWithdrawDurationLessThan1Day() public {
        vm.expectRevert(minimalWithdrawDurationLessThan1Day.selector);
        bittyVault.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({
                amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 23 hours, replaceTrusteeDuration: 0
            })
        );
    }

    function test_GetMoneyFailedIfWithdrawalInDuration() public {
        vm.deal(address(bittyVault), 10 ether);
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        uint256 usdtAmount = beneficiarySettings.amountPerWithdrawal * 10 ** mockUSDT.decimals();
        deal(address(mockUSDT), address(bittyVault), usdtAmount);
        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDT));
        deal(address(mockUSDT), address(bittyVault), usdtAmount);
        vm.warp(block.timestamp + 29 days);
        vm.expectRevert(BeneficiaryWithdrawalInLimitDays.selector);
        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDT));
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
        bittyVault.getMoneyFromEvent("Marriage", address(mockUSDT));
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
        bittyVault.getMoneyFromEvent("", address(mockUSDT));
    }

    function test_GetMoneyFromEventWithAmountSuccess() public {
        eventNames[0] = "Marriage";
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: marriageMoney, isPercentage: false});
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        uint256 marriageMoneyTokens = marriageMoney * 10 ** mockUSDT.decimals();
        deal(address(mockUSDT), address(bittyVault), marriageMoneyTokens);
        vm.prank(eventInputAddress);
        bittyVault.getMoneyFromEvent("Marriage", address(mockUSDT));
        assertEq(mockUSDT.balanceOf(beneficiary), marriageMoneyTokens);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0);
    }

    function test_GetMoneyFromEventWithpercentageSuccess() public {
        eventNames[0] = "Marriage";
        uint256 percentage = 1000;
        triggerEvents[0] =
            IBeneficiary.TriggerEvent({triggerAddress: eventInputAddress, amount: percentage, isPercentage: true});
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        bittyVault.addTriggerEvents(eventNames, triggerEvents);
        uint256 marriageMoneyTokens = marriageMoney * 10 ** mockUSDT.decimals();
        deal(address(mockUSDT), address(bittyVault), marriageMoneyTokens);
        vm.prank(eventInputAddress);
        bittyVault.getMoneyFromEvent("Marriage", address(mockUSDT));
        uint256 percentageMoney = marriageMoneyTokens * percentage / 10000;
        assertEq(mockUSDT.balanceOf(beneficiary), percentageMoney);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), marriageMoneyTokens - percentageMoney);
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
        bittyVault.getMoneyFromEvent(eventNames[0], address(mockUSDT));
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
        bittyVault.getMoneyByTimestamp(timestamps[0], address(mockUSDT));
    }

    function test_GetMoneyByTimestampFailedIfTimestampNotFound() public {
        timestamps[0] = block.timestamp;
        vm.expectRevert(TimestampNotFound.selector);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0], address(mockUSDT));
    }

    function test_GetMoneyByTimestampFailedIfTimestampIsInTheFuture() public {
        timestamps[0] = block.timestamp + 1 days;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        bittyVault.addTimeEvents(timestamps, timeEvents);
        vm.expectRevert(TimestampIsInTheFuture.selector);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0], address(mockUSDT));
    }

    function test_GetMoneyFromTimeEventSuccessByAmount() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        timestamps[0] = block.timestamp;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: marriageMoney, isPercentage: false});
        bittyVault.addTimeEvents(timestamps, timeEvents);
        uint256 marriageMoneyTokens = marriageMoney * 10 ** mockUSDT.decimals();
        deal(address(mockUSDT), address(bittyVault), marriageMoneyTokens);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0], address(mockUSDT));
        assertEq(mockUSDT.balanceOf(beneficiary), marriageMoneyTokens);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0);
    }

    function test_GetMoneyFromTimeEventSuccessByPercentage() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        timestamps[0] = block.timestamp;
        timeEvents[0] = IBeneficiary.TimeEvent({amount: 1000, isPercentage: true});
        bittyVault.addTimeEvents(timestamps, timeEvents);
        uint256 marriageMoneyTokensUSDT = marriageMoney * 10 ** mockUSDT.decimals();
        uint256 marriageMoneyTokensUSDC = marriageMoney * 10 ** mockUSDC.decimals();
        deal(address(mockUSDT), address(bittyVault), marriageMoneyTokensUSDT);
        deal(address(mockUSDC), address(bittyVault), marriageMoneyTokensUSDC);
        vm.prank(beneficiary);
        bittyVault.getMoneyByTimestamp(timestamps[0], address(mockUSDT));

        uint256 percentageMoneyUSDT = marriageMoneyTokensUSDT * 1000 / 10000;
        uint256 percentageMoneyUSDC = marriageMoneyTokensUSDC * 1000 / 10000;
        assertEq(mockUSDT.balanceOf(beneficiary), percentageMoneyUSDT);
        assertEq(mockUSDC.balanceOf(beneficiary), percentageMoneyUSDC);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), marriageMoneyTokensUSDT - percentageMoneyUSDT);
        assertEq(mockUSDC.balanceOf(address(bittyVault)), marriageMoneyTokensUSDC - percentageMoneyUSDC);
    }

    function test_GetUSDTSuccessFromTrustFor100USD() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);

        uint256 usdtAmountBase = beneficiarySettings.amountPerWithdrawal;
        uint256 usdtAmountTokens = usdtAmountBase * 10 ** mockUSDT.decimals();
        deal(address(mockUSDT), address(bittyVault), usdtAmountTokens);

        assertEq(mockUSDT.balanceOf(address(bittyVault)), usdtAmountTokens);
        assertEq(mockUSDT.balanceOf(beneficiary), 0);

        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDT));

        assertEq(mockUSDT.balanceOf(beneficiary), usdtAmountTokens);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0);

        assertEq(bittyVault.lastWithdrawalTime(), block.timestamp);
    }

    function test_GetUSDTFailedIfUSDTInsufficient() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);

        uint256 tokenAmountBase = beneficiarySettings.amountPerWithdrawal;
        uint256 tokenAmountTokens = tokenAmountBase * 10 ** mockUSDT.decimals();
        uint256 partialUSDTTokens = tokenAmountTokens / 2;
        deal(address(mockUSDT), address(bittyVault), partialUSDTTokens);
        deal(address(mockUSDC), address(bittyVault), tokenAmountBase * 10 ** mockUSDC.decimals());

        assertEq(mockUSDT.balanceOf(address(bittyVault)), partialUSDTTokens);
        assertEq(mockUSDC.balanceOf(address(bittyVault)), tokenAmountBase * 10 ** mockUSDC.decimals());
        assertEq(mockUSDT.balanceOf(beneficiary), 0);
        assertEq(mockUSDC.balanceOf(beneficiary), 0);

        vm.prank(beneficiary);
        vm.expectRevert(InsufficientStablecoinBalance.selector);
        bittyVault.getMoney(address(mockUSDT));
    }

    function test_GetMoneyFailedIfBothUSDTAndUSDCInsufficient() public {
        bittyVault.setBeneficiarySettings(beneficiarySettings);

        uint256 partialAmountBase = beneficiarySettings.amountPerWithdrawal / 2;
        uint256 partialAmountUSDT = partialAmountBase * 10 ** mockUSDT.decimals();
        uint256 partialAmountUSDC = partialAmountBase * 10 ** mockUSDC.decimals();
        deal(address(mockUSDT), address(bittyVault), partialAmountUSDT);
        deal(address(mockUSDC), address(bittyVault), partialAmountUSDC);

        vm.expectRevert(InsufficientStablecoinBalance.selector);
        vm.prank(beneficiary);
        bittyVault.getMoney(address(mockUSDT));
    }

    function test_ReplaceTrustee_Success() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);
        bittyVault.setToIrrevocable();

        vm.warp(block.timestamp + 181 days);

        vm.prank(beneficiary);
        bittyVault.replaceTrustee(newTrustee);

        assertEq(bittyVault.trustee(), newTrustee);
    }

    function test_ReplaceTrustee_RevertsIfNotBeneficiary() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);
        bittyVault.setToIrrevocable();

        vm.warp(block.timestamp + 181 days);

        vm.expectRevert("Only beneficiary");
        bittyVault.replaceTrustee(newTrustee);
    }

    function test_ReplaceTrustee_RevertsIfNotIrrevocable() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);

        vm.warp(block.timestamp + 181 days);

        vm.prank(beneficiary);
        vm.expectRevert("Only Irrevocable");
        bittyVault.replaceTrustee(newTrustee);
    }

    function test_ReplaceTrustee_RevertsIfAddressZero() public {
        address trustee = makeAddr("trustee");
        bittyVault.setTrustee(trustee);
        bittyVault.setToIrrevocable();

        vm.warp(block.timestamp + 181 days);

        vm.prank(beneficiary);
        vm.expectRevert(AddressZero.selector);
        bittyVault.replaceTrustee(address(0));
    }

    function test_ReplaceTrustee_RevertsIfTrusteeStillAlive() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);

        bittyVault.setBeneficiarySettings(beneficiarySettings);
        bittyVault.setToIrrevocable();

        vm.prank(trustee);
        bittyVault.trusteePing();

        vm.prank(beneficiary);
        vm.expectRevert(InsufficientStablecoinBalance.selector);
        bittyVault.getMoney(address(mockUSDT));

        vm.warp(block.timestamp + 30 days);

        vm.prank(beneficiary);
        vm.expectRevert(ReplaceTrusteeFailed.selector);
        bittyVault.replaceTrustee(newTrustee);
    }

    function test_ReplaceTrustee_SuccessAfterTrusteePingExpired() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);
        bittyVault.setToIrrevocable();

        vm.prank(trustee);
        bittyVault.trusteePing();

        vm.warp(block.timestamp + 181 days);

        vm.prank(beneficiary);
        bittyVault.replaceTrustee(newTrustee);

        assertEq(bittyVault.trustee(), newTrustee);
    }

    function test_ReplaceTrustee_SuccessWithCustomInvalidAfterNoPing() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);
        bittyVault.setToIrrevocable();

        vm.prank(address(this));
        bittyVault.setTrusteeInvalidAfterNoPing(30 days);

        vm.warp(block.timestamp + 31 days);

        vm.prank(beneficiary);
        bittyVault.replaceTrustee(newTrustee);

        assertEq(bittyVault.trustee(), newTrustee);
    }

    function test_ReplaceTrustee_RevertsIfTrusteeStillAliveWithCustomDuration() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);

        bittyVault.setBeneficiarySettings(beneficiarySettings);
        bittyVault.setToIrrevocable();

        vm.prank(address(this));
        bittyVault.setTrusteeInvalidAfterNoPing(30 days);

        vm.prank(trustee);
        bittyVault.trusteePing();

        vm.prank(beneficiary);
        vm.expectRevert(InsufficientStablecoinBalance.selector);
        bittyVault.getMoney(address(mockUSDT));

        vm.warp(block.timestamp + 29 days);

        vm.prank(beneficiary);
        vm.expectRevert(ReplaceTrusteeFailed.selector);
        bittyVault.replaceTrustee(newTrustee);
    }

    function test_ReplaceTrustee_RevertsIfNotInitialized() public {
        BittyVault newVault = new BittyVault();
        address newTrustee = makeAddr("newTrustee");

        vm.expectRevert("Trust not initialized");
        newVault.replaceTrustee(newTrustee);
    }

    function test_ReplaceTrustee_SuccessWhenTrusteeNeverPinged() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);
        bittyVault.setToIrrevocable();

        vm.warp(block.timestamp + 181 days);

        vm.prank(beneficiary);
        bittyVault.replaceTrustee(newTrustee);

        assertEq(bittyVault.trustee(), newTrustee);
    }

    function test_ReplaceTrustee_SuccessWhenStableNotEnoughAfterDuration() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);

        IBeneficiary.BeneficiarySettings memory settings = IBeneficiary.BeneficiarySettings({
            amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 30 days, replaceTrusteeDuration: 60 days
        });
        bittyVault.setBeneficiarySettings(settings);
        bittyVault.setToIrrevocable();

        vm.prank(trustee);
        bittyVault.trusteePing();

        vm.prank(beneficiary);
        vm.expectRevert(InsufficientStablecoinBalance.selector);
        bittyVault.getMoney(address(mockUSDT));

        vm.warp(block.timestamp + 61 days);

        vm.prank(beneficiary);
        bittyVault.replaceTrustee(newTrustee);

        assertEq(bittyVault.trustee(), newTrustee);
    }

    function test_ReplaceTrustee_RevertsWhenStableEnoughAfterDuration() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);

        IBeneficiary.BeneficiarySettings memory settings = IBeneficiary.BeneficiarySettings({
            amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 30 days, replaceTrusteeDuration: 60 days
        });
        bittyVault.setBeneficiarySettings(settings);
        bittyVault.setToIrrevocable();

        vm.prank(trustee);
        bittyVault.trusteePing();

        vm.prank(beneficiary);
        vm.expectRevert(InsufficientStablecoinBalance.selector);
        bittyVault.getMoney(address(mockUSDT));

        vm.warp(block.timestamp + 61 days);

        uint256 usdtAmount = withdrawMoney * 10 ** mockUSDT.decimals();
        deal(address(mockUSDT), address(bittyVault), usdtAmount);

        vm.prank(beneficiary);
        vm.expectRevert(ReplaceTrusteeFailed.selector);
        bittyVault.replaceTrustee(newTrustee);

        assertEq(bittyVault.trustee(), trustee);
    }

    function test_ReplaceTrustee_RevertsWhenDurationNotPassed() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);

        IBeneficiary.BeneficiarySettings memory settings = IBeneficiary.BeneficiarySettings({
            amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 30 days, replaceTrusteeDuration: 60 days
        });
        bittyVault.setBeneficiarySettings(settings);
        bittyVault.setToIrrevocable();

        vm.prank(trustee);
        bittyVault.trusteePing();

        vm.prank(beneficiary);
        vm.expectRevert(InsufficientStablecoinBalance.selector);
        bittyVault.getMoney(address(mockUSDT));

        vm.warp(block.timestamp + 59 days);

        vm.prank(beneficiary);
        vm.expectRevert(ReplaceTrusteeFailed.selector);
        bittyVault.replaceTrustee(newTrustee);
    }

    function test_ReplaceTrustee_SuccessWithDefaultReplaceTrusteeDuration() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);

        IBeneficiary.BeneficiarySettings memory settings = IBeneficiary.BeneficiarySettings({
            amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 30 days, replaceTrusteeDuration: 0
        });
        bittyVault.setBeneficiarySettings(settings);
        bittyVault.setToIrrevocable();

        vm.prank(trustee);
        bittyVault.trusteePing();

        vm.prank(beneficiary);
        vm.expectRevert(InsufficientStablecoinBalance.selector);
        bittyVault.getMoney(address(mockUSDT));

        vm.warp(block.timestamp + 61 days);

        vm.prank(beneficiary);
        bittyVault.replaceTrustee(newTrustee);

        assertEq(bittyVault.trustee(), newTrustee);
    }

    function test_ReplaceTrustee_SuccessWhenNoPreviousWithdrawal() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);

        IBeneficiary.BeneficiarySettings memory settings = IBeneficiary.BeneficiarySettings({
            amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 30 days, replaceTrusteeDuration: 60 days
        });
        bittyVault.setBeneficiarySettings(settings);
        bittyVault.setToIrrevocable();

        vm.prank(trustee);
        bittyVault.trusteePing();

        vm.warp(61 days);

        vm.prank(beneficiary);
        bittyVault.replaceTrustee(newTrustee);

        assertEq(bittyVault.trustee(), newTrustee);
    }

    function test_ReplaceTrustee_SuccessWhenMultipleStableCoinsNoneHaveEnough() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);

        IBeneficiary.BeneficiarySettings memory settings = IBeneficiary.BeneficiarySettings({
            amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 30 days, replaceTrusteeDuration: 60 days
        });
        bittyVault.setBeneficiarySettings(settings);
        bittyVault.setToIrrevocable();

        vm.prank(trustee);
        bittyVault.trusteePing();

        vm.prank(beneficiary);
        vm.expectRevert(InsufficientStablecoinBalance.selector);
        bittyVault.getMoney(address(mockUSDT));

        vm.warp(block.timestamp + 61 days);

        uint256 partialAmount = (withdrawMoney * 10 ** mockUSDT.decimals()) / 2;
        deal(address(mockUSDT), address(bittyVault), partialAmount);

        uint256 partialAmountUSDC = (withdrawMoney * 10 ** mockUSDC.decimals()) / 2;
        deal(address(mockUSDC), address(bittyVault), partialAmountUSDC);

        vm.prank(beneficiary);
        bittyVault.replaceTrustee(newTrustee);

        assertEq(bittyVault.trustee(), newTrustee);
    }

    function test_ReplaceTrustee_EdgeCaseExactlyAtDuration() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);

        IBeneficiary.BeneficiarySettings memory settings = IBeneficiary.BeneficiarySettings({
            amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 30 days, replaceTrusteeDuration: 60 days
        });
        bittyVault.setBeneficiarySettings(settings);
        bittyVault.setToIrrevocable();

        vm.prank(trustee);
        bittyVault.trusteePing();

        vm.prank(beneficiary);
        vm.expectRevert(InsufficientStablecoinBalance.selector);
        bittyVault.getMoney(address(mockUSDT));

        vm.warp(block.timestamp + 60 days);

        vm.prank(beneficiary);
        bittyVault.replaceTrustee(newTrustee);

        assertEq(bittyVault.trustee(), newTrustee);
    }

    function test_ReplaceTrustee_EdgeCaseExactlyAtPingExpiry() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);

        IBeneficiary.BeneficiarySettings memory settings = IBeneficiary.BeneficiarySettings({
            amountPerWithdrawal: withdrawMoney, minimalWithdrawDuration: 30 days, replaceTrusteeDuration: 200 days
        });
        bittyVault.setBeneficiarySettings(settings);
        bittyVault.setToIrrevocable();

        vm.prank(trustee);
        bittyVault.trusteePing();

        vm.prank(beneficiary);
        vm.expectRevert(InsufficientStablecoinBalance.selector);
        bittyVault.getMoney(address(mockUSDT));

        uint256 withdrawalTime = block.timestamp;

        vm.warp(withdrawalTime + 180 days);

        vm.prank(beneficiary);
        vm.expectRevert(ReplaceTrusteeFailed.selector);
        bittyVault.replaceTrustee(newTrustee);
    }

    function test_ReplaceTrustee_TrusteeCannotCall() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        bittyVault.setTrustee(trustee);
        bittyVault.setBeneficiary(beneficiary);
        bittyVault.setToIrrevocable();

        vm.warp(block.timestamp + 181 days);

        vm.prank(trustee);
        vm.expectRevert("Only beneficiary");
        bittyVault.replaceTrustee(newTrustee);
    }

    function test_ReplaceTrustee_UnauthorizedCannotCall() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        address unauthorized = makeAddr("unauthorized");
        bittyVault.setTrustee(trustee);
        bittyVault.setBeneficiary(beneficiary);
        bittyVault.setToIrrevocable();

        vm.warp(block.timestamp + 181 days);

        vm.prank(unauthorized);
        vm.expectRevert("Only beneficiary");
        bittyVault.replaceTrustee(newTrustee);
    }

    function test_ReplaceTrustee_AssetManagerCannotCall() public {
        address trustee = makeAddr("trustee");
        address newTrustee = makeAddr("newTrustee");
        address assetManager = makeAddr("assetManager");
        bittyVault.setTrustee(trustee);
        bittyVault.setBeneficiary(beneficiary);
        bittyVault.setToIrrevocable();

        vm.warp(block.timestamp + 181 days);

        vm.prank(assetManager);
        vm.expectRevert("Only beneficiary");
        bittyVault.replaceTrustee(newTrustee);
    }
}
