// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {Trust} from "../src/Trust.sol";
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

    function setUp() public {
        mockWETH = new MockWETH();
        mockUSDT = new MockUSDT();
        mockUSDC = new MockUSDC();
        bittyVault = new BittyVault();
        beneficiary = makeAddr("alice");
        eventInputAddress = makeAddr("anyone");
        bittyVault.setAsset(IAssetManager.AssetType.WETH, address(mockWETH));
        bittyVault.setAsset(IAssetManager.AssetType.USDT, address(mockUSDT));
        bittyVault.setAsset(IAssetManager.AssetType.USDC, address(mockUSDC));
        bittyVault.initialize(address(this));
        bittyVault.setBeneficiary(beneficiary);
        beneficiarySettings = IBeneficiary.BeneficiarySettings({
            amountPerWithdrawal: 100 * 1e6, minimalDaysBetweenWithdrawals: 30, withdrawUSDTFirst: true
        });
    }

    function test_GetMoneyFailedIfNotBeneficiary() public {
        vm.deal(address(bittyVault), 10 ether);
        vm.expectRevert("Only beneficiary");
        bittyVault.getMoney();
    }

    function test_GetMoneyFailedIfNoBeneficiarySettings() public {
        vm.deal(address(bittyVault), 10 ether);
        vm.expectRevert(Trust.BeneficiarySettingsNotSet.selector);
        vm.prank(beneficiary);
        bittyVault.getMoney();
    }

    function test_SetBeneficiarySettingFailedIfAmountPerWithdrawalIsZero() public {
        vm.expectRevert(Trust.AmountPerWithdrawalIsZero.selector);
        bittyVault.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({
                amountPerWithdrawal: 0, minimalDaysBetweenWithdrawals: 30, withdrawUSDTFirst: false
            })
        );
    }

    function test_GetMoneyFailedIfMinimalDaysBetweenWithdrawalsIsZero() public {
        vm.expectRevert(Trust.MinimalDaysBetweenWithdrawalsIsZero.selector);
        bittyVault.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({
                amountPerWithdrawal: 100 * 10 ** 6, minimalDaysBetweenWithdrawals: 0, withdrawUSDTFirst: false
            })
        );
    }

    function test_GetMoneyFailedIfWithdrawalInLimitDays() public {
        vm.deal(address(bittyVault), 10 ether);
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        uint256 usdtAmount = beneficiarySettings.amountPerWithdrawal;
        mockUSDT.mint(address(bittyVault), usdtAmount);
        vm.prank(beneficiary);
        bittyVault.getMoney();
        mockUSDT.mint(address(bittyVault), usdtAmount);
        vm.warp(block.timestamp + 29 days);
        vm.expectRevert(Trust.BeneficiaryWithdrawalInLimitDays.selector);
        vm.prank(beneficiary);
        bittyVault.getMoney();
    }

    function test_SetBeneficiaryReleaseEventFailedIfEventNameIsEmpty() public {
        vm.expectRevert(Trust.EventNameIsEmpty.selector);
        bittyVault.addBeneficiaryReleaseEvent(
            "", IBeneficiary.ReleaseEvent({triggerAddress: eventInputAddress, amount: 1000000})
        );
    }

    function test_SetBeneficiaryReleaseEventFailedIfEventInputAddressIsZero() public {
        vm.expectRevert(Trust.AddressZero.selector);
        bittyVault.addBeneficiaryReleaseEvent(
            "Marry", IBeneficiary.ReleaseEvent({triggerAddress: address(0), amount: 1000000})
        );
    }

    function test_SetBeneficiaryReleaseEventFailedIfAmountIsZero() public {
        vm.expectRevert(Trust.AmountIsZero.selector);
        bittyVault.addBeneficiaryReleaseEvent(
            "Marry", IBeneficiary.ReleaseEvent({triggerAddress: eventInputAddress, amount: 0})
        );
    }

    function test_SetBeneficiaryReleaseEventFailedIfEventNameDuplicated() public {
        bittyVault.addBeneficiaryReleaseEvent(
            "Marry", IBeneficiary.ReleaseEvent({triggerAddress: eventInputAddress, amount: 1000000})
        );
        vm.expectRevert(Trust.EventNameDuplicated.selector);
        bittyVault.addBeneficiaryReleaseEvent(
            "Marry", IBeneficiary.ReleaseEvent({triggerAddress: eventInputAddress, amount: 1000000})
        );
    }

    function test_SetBeneficiaryReleaseEventFailedIfEventTriggerError() public {
        bittyVault.addBeneficiaryReleaseEvent(
            "Marry", IBeneficiary.ReleaseEvent({triggerAddress: eventInputAddress, amount: 1000000})
        );
        vm.expectRevert(Trust.EventTriggerError.selector);
        bittyVault.getMoneyFromEvent("Marry");
    }

    function test_SetBenefciaryReleaseEventFailedIfIrrevocable() public {
        bittyVault.setToIrrevocable();
        vm.expectRevert(Trust.Irrevocable.selector);
        bittyVault.addBeneficiaryReleaseEvent(
            "Marry", IBeneficiary.ReleaseEvent({triggerAddress: eventInputAddress, amount: 1000000})
        );
    }

    function test_RemoveBeneficiaryReleaseEventFailedIfIrrevocable() public {
        bittyVault.setToIrrevocable();
        vm.expectRevert(Trust.Irrevocable.selector);
        bittyVault.removeBeneficiaryReleaseEvent("Marry");
    }

    function test_RemoveBeneficiaryReleaseEventFailedIfEventNameIsEmpty() public {
        vm.expectRevert(Trust.EventNameIsEmpty.selector);
        bittyVault.removeBeneficiaryReleaseEvent("");
    }

    function test_RemoveBeneficiaryReleaseEventFailedIfEventNameNotFound() public {
        vm.expectRevert(Trust.EventNameNotFound.selector);
        bittyVault.removeBeneficiaryReleaseEvent("Marry");
    }

    function test_RemoveBeneficiaryReleaseEventSuccess() public {
        bittyVault.addBeneficiaryReleaseEvent(
            "Marry", IBeneficiary.ReleaseEvent({triggerAddress: eventInputAddress, amount: 1000000})
        );
        bittyVault.removeBeneficiaryReleaseEvent("Marry");
    }

    function test_GetMoneyFromEventSuccess() public {
        uint256 marryMoney = 1000000;
        bittyVault.setBeneficiarySettings(beneficiarySettings);
        bittyVault.addBeneficiaryReleaseEvent(
            "Marry", IBeneficiary.ReleaseEvent({triggerAddress: eventInputAddress, amount: marryMoney})
        );
        mockUSDT.mint(address(bittyVault), marryMoney);
        vm.prank(eventInputAddress);
        bittyVault.getMoneyFromEvent("Marry");
        assertEq(mockUSDT.balanceOf(beneficiary), marryMoney, "Beneficiary should receive 1000000 USDT");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0, "Trust should have 0 USDT after transfer");
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

        vm.expectRevert(Trust.InsufficientStablecoinBalance.selector);
        vm.prank(beneficiary);
        bittyVault.getMoney();
    }

    function test_GetUSDCFirstWhenWithdrawUSDTFirstIsFalse() public {
        bittyVault.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({
                amountPerWithdrawal: 100 * 10 ** 6, minimalDaysBetweenWithdrawals: 30, withdrawUSDTFirst: false
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
