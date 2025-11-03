// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {BittyTrust} from "../src/BittyTrust.sol";
import {IBeneficiary} from "../src/interfaces/IBeneficiary.sol";

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

contract BittyTrustBeneficiaryTest is Test {
    BittyTrust public bittyTrust;
    MockWETH public mockWETH;
    MockUSDT public mockUSDT;
    MockUSDC public mockUSDC;
    address public beneficiary;
    IBeneficiary.BeneficiarySettings public beneficiarySettings;

    function setUp() public {
        mockWETH = new MockWETH();
        mockUSDT = new MockUSDT();
        mockUSDC = new MockUSDC();
        bittyTrust = new BittyTrust();
        beneficiary = makeAddr("alice");
        bittyTrust.setWETH(address(mockWETH));
        bittyTrust.setUSDT(address(mockUSDT));
        bittyTrust.setUSDC(address(mockUSDC));
        bittyTrust.initialize(address(this));
        bittyTrust.setBeneficiary(beneficiary);
        beneficiarySettings = IBeneficiary.BeneficiarySettings({
            amountPerWithdrawal: 100 * 1e6, minimalDaysBetweenWithdrawals: 30, withdrawUSDTFirst: true
        });
    }

    function test_GetMoneyFailedIfNotBeneficiary() public {
        vm.deal(address(bittyTrust), 10 ether);
        vm.expectRevert("Only beneficiary");
        bittyTrust.getMoney();
    }

    function test_GetMoneyFailedIfNoBeneficiarySettings() public {
        vm.deal(address(bittyTrust), 10 ether);
        vm.expectRevert(BittyTrust.BeneficiarySettingsNotSet.selector);
        vm.prank(beneficiary);
        bittyTrust.getMoney();
    }

    function test_SetBeneficiarySettingFailedIfAmountPerWithdrawalIsZero() public {
        vm.expectRevert(BittyTrust.AmountPerWithdrawalIsZero.selector);
        bittyTrust.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({
                amountPerWithdrawal: 0, minimalDaysBetweenWithdrawals: 30, withdrawUSDTFirst: false
            })
        );
    }

    function test_GetMoneyFailedIfMinimalDaysBetweenWithdrawalsIsZero() public {
        vm.expectRevert(BittyTrust.MinimalDaysBetweenWithdrawalsIsZero.selector);
        bittyTrust.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({
                amountPerWithdrawal: 100 * 10 ** 6, minimalDaysBetweenWithdrawals: 0, withdrawUSDTFirst: false
            })
        );
    }

    function test_GetMoneyFailedIfWithdrawalInLimitDays() public {
        vm.deal(address(bittyTrust), 10 ether);
        bittyTrust.setBeneficiarySettings(beneficiarySettings);
        uint256 usdtAmount = beneficiarySettings.amountPerWithdrawal;
        mockUSDT.mint(address(bittyTrust), usdtAmount);
        vm.prank(beneficiary);
        bittyTrust.getMoney();
        mockUSDT.mint(address(bittyTrust), usdtAmount);
        vm.warp(block.timestamp + 29 days);
        vm.expectRevert(BittyTrust.BeneficiaryWithdrawalInLimitDays.selector);
        vm.prank(beneficiary);
        bittyTrust.getMoney();
    }

    function test_GetUSDTSuccessFromTrustFor100USD() public {
        bittyTrust.setBeneficiarySettings(beneficiarySettings);

        uint256 usdtAmount = beneficiarySettings.amountPerWithdrawal;
        mockUSDT.mint(address(bittyTrust), usdtAmount);

        assertEq(mockUSDT.balanceOf(address(bittyTrust)), usdtAmount, "Trust should have 100 USDT");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDT");

        vm.prank(beneficiary);
        bittyTrust.getMoney();

        assertEq(mockUSDT.balanceOf(beneficiary), usdtAmount, "Beneficiary should receive 100 USDT");
        assertEq(mockUSDT.balanceOf(address(bittyTrust)), 0, "Trust should have 0 USDT after transfer");

        assertEq(bittyTrust.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }

    function test_GetUSDCFallbackWhenUSDTInsufficient() public {
        bittyTrust.setBeneficiarySettings(beneficiarySettings);

        uint256 tokenAmount = beneficiarySettings.amountPerWithdrawal;
        uint256 partialUSDT = beneficiarySettings.amountPerWithdrawal / 2;
        mockUSDT.mint(address(bittyTrust), partialUSDT);
        mockUSDC.mint(address(bittyTrust), tokenAmount);

        assertEq(mockUSDT.balanceOf(address(bittyTrust)), partialUSDT, "Trust should have 50 USDT");
        assertEq(mockUSDC.balanceOf(address(bittyTrust)), tokenAmount, "Trust should have 100 USDC");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDT");
        assertEq(mockUSDC.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDC");

        vm.prank(beneficiary);
        bittyTrust.getMoney();

        assertEq(mockUSDC.balanceOf(beneficiary), tokenAmount, "Beneficiary should receive 100 USDC");
        assertEq(mockUSDC.balanceOf(address(bittyTrust)), 0, "Trust should have 0 USDC after transfer");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should not receive USDT");
        assertEq(mockUSDT.balanceOf(address(bittyTrust)), partialUSDT, "Trust should still have 50 USDT");

        assertEq(bittyTrust.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }

    function test_GetMoneyFailedIfBothUSDTAndUSDCInsufficient() public {
        bittyTrust.setBeneficiarySettings(beneficiarySettings);

        uint256 partialAmount = beneficiarySettings.amountPerWithdrawal / 2;
        mockUSDT.mint(address(bittyTrust), partialAmount);
        mockUSDC.mint(address(bittyTrust), partialAmount);

        vm.expectRevert(BittyTrust.InsufficientStablecoinBalance.selector);
        vm.prank(beneficiary);
        bittyTrust.getMoney();
    }

    function test_GetUSDCFirstWhenWithdrawUSDTFirstIsFalse() public {
        bittyTrust.setBeneficiarySettings(
            IBeneficiary.BeneficiarySettings({
                amountPerWithdrawal: 100 * 10 ** 6, minimalDaysBetweenWithdrawals: 30, withdrawUSDTFirst: false
            })
        );

        uint256 tokenAmount = beneficiarySettings.amountPerWithdrawal;
        mockUSDT.mint(address(bittyTrust), tokenAmount);
        mockUSDC.mint(address(bittyTrust), tokenAmount);

        assertEq(mockUSDT.balanceOf(address(bittyTrust)), tokenAmount, "Trust should have 100 USDT");
        assertEq(mockUSDC.balanceOf(address(bittyTrust)), tokenAmount, "Trust should have 100 USDC");

        vm.prank(beneficiary);
        bittyTrust.getMoney();

        assertEq(mockUSDC.balanceOf(beneficiary), tokenAmount, "Beneficiary should receive 100 USDC");
        assertEq(mockUSDC.balanceOf(address(bittyTrust)), 0, "Trust should have 0 USDC after transfer");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should not receive USDT");
        assertEq(mockUSDT.balanceOf(address(bittyTrust)), tokenAmount, "Trust should still have 100 USDT");

        assertEq(bittyTrust.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }

    function test_GetUSDTFirstWhenWithdrawUSDTFirstIsTrue() public {
        bittyTrust.setBeneficiarySettings(beneficiarySettings);

        uint256 tokenAmount = beneficiarySettings.amountPerWithdrawal;
        mockUSDT.mint(address(bittyTrust), tokenAmount);
        mockUSDC.mint(address(bittyTrust), tokenAmount);

        assertEq(mockUSDT.balanceOf(address(bittyTrust)), tokenAmount, "Trust should have 100 USDT");
        assertEq(mockUSDC.balanceOf(address(bittyTrust)), tokenAmount, "Trust should have 100 USDC");

        vm.prank(beneficiary);
        bittyTrust.getMoney();

        assertEq(mockUSDT.balanceOf(beneficiary), tokenAmount, "Beneficiary should receive 100 USDT");
        assertEq(mockUSDT.balanceOf(address(bittyTrust)), 0, "Trust should have 0 USDT after transfer");
        assertEq(mockUSDC.balanceOf(beneficiary), 0, "Beneficiary should not receive USDC");
        assertEq(mockUSDC.balanceOf(address(bittyTrust)), tokenAmount, "Trust should still have 100 USDC");

        assertEq(bittyTrust.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }

    function test_GetUSDTFallbackWhenUSDCInsufficientAndWithdrawUSDTFirstIsFalse() public {
        bittyTrust.setBeneficiarySettings(beneficiarySettings);

        uint256 tokenAmount = beneficiarySettings.amountPerWithdrawal;
        uint256 partialUSDC = tokenAmount / 2;
        mockUSDC.mint(address(bittyTrust), partialUSDC);
        mockUSDT.mint(address(bittyTrust), tokenAmount);

        assertEq(mockUSDC.balanceOf(address(bittyTrust)), partialUSDC, "Trust should have 50 USDC");
        assertEq(mockUSDT.balanceOf(address(bittyTrust)), tokenAmount, "Trust should have 100 USDT");
        assertEq(mockUSDC.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDC");
        assertEq(mockUSDT.balanceOf(beneficiary), 0, "Beneficiary should start with 0 USDT");

        vm.prank(beneficiary);
        bittyTrust.getMoney();

        assertEq(mockUSDT.balanceOf(beneficiary), tokenAmount, "Beneficiary should receive 100 USDT");
        assertEq(mockUSDT.balanceOf(address(bittyTrust)), 0, "Trust should have 0 USDT after transfer");
        assertEq(mockUSDC.balanceOf(beneficiary), 0, "Beneficiary should not receive USDC");
        assertEq(mockUSDC.balanceOf(address(bittyTrust)), partialUSDC, "Trust should still have 50 USDC");

        assertEq(bittyTrust.lastWithdrawalTime(), block.timestamp, "lastWithdrawalTime should be updated");
    }
}
