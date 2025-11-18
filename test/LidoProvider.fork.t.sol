// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {LidoProvider} from "../src/providers/LidoProvider.sol";
import {mainnet} from "../script/addresses.sol";
import {IStETH, IUnstETH} from "../src/libs/Lido.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";

contract TestLidoProviderFork is Test {
    using Address for address;

    LidoProvider public lidoProvider;
    IStETH public stETH;
    IUnstETH public unstETH;
    IWETH public weth;

    function setUp() public {
        vm.createSelectFork("mainnet");
        lidoProvider = new LidoProvider(mainnet.STETH, mainnet.UNSTETH, mainnet.WETH);
        lidoProvider.initialize(address(this));
        stETH = IStETH(mainnet.STETH);
        unstETH = IUnstETH(mainnet.UNSTETH);
        weth = IWETH(mainnet.WETH);
    }

    function test_Initialize() public view {
        assertEq(lidoProvider.owner(), address(this));
    }

    function test_InitializeRevertWhenCalledTwice() public {
        LidoProvider newProvider = new LidoProvider(mainnet.STETH, mainnet.UNSTETH, mainnet.WETH);
        newProvider.initialize(address(this));
        vm.expectRevert();
        newProvider.initialize(address(1));
    }

    function test_Supply() public {
        uint256 supplyAmount = 1 ether;
        uint256 balanceBefore = stETH.balanceOf(address(lidoProvider));

        // Supply ETH to Lido
        lidoProvider.supply{value: supplyAmount}(address(0), supplyAmount);

        uint256 balanceAfter = stETH.balanceOf(address(lidoProvider));
        // stETH balance should increase (may have small rounding differences)
        assertGt(balanceAfter, balanceBefore);
        // Should receive approximately the same amount in stETH (allowing for small differences)
        assertApproxEqAbs(balanceAfter - balanceBefore, supplyAmount, 10);
    }

    function test_SupplyRevertWhenAssetNotZero() public {
        uint256 supplyAmount = 1 ether;
        vm.deal(address(this), supplyAmount);

        vm.expectRevert(LidoProvider.InvalidAsset.selector);
        lidoProvider.supply(address(1), supplyAmount);
    }

    function test_SupplyRevertWhenAmountNotMatchValue() public {
        uint256 supplyAmount = 1 ether;
        vm.deal(address(this), supplyAmount);

        // When asset is not address(0) and amount != msg.value, it should revert
        vm.expectRevert(LidoProvider.InvalidAsset.selector);
        lidoProvider.supply{value: supplyAmount / 2}(address(1), supplyAmount);
    }

    function test_SupplyRevertWhenNotOwner() public {
        uint256 supplyAmount = 1 ether;
        vm.deal(address(1), supplyAmount);

        vm.prank(address(1));
        vm.expectRevert();
        lidoProvider.supply{value: supplyAmount}(address(0), supplyAmount);
    }

    function test_Withdraw() public {
        // First supply some ETH
        uint256 supplyAmount = 1 ether;
        vm.deal(address(this), supplyAmount);
        lidoProvider.supply{value: supplyAmount}(address(0), supplyAmount);

        uint256 stETHBalance = stETH.balanceOf(address(lidoProvider));
        assertGt(stETHBalance, 0);

        // Request withdrawal
        uint256 withdrawAmount = stETHBalance / 2;
        lidoProvider.withdraw(address(0), withdrawAmount);

        // Balance should decrease after withdrawal request
        uint256 balanceAfter = stETH.balanceOf(address(lidoProvider));
        assertLt(balanceAfter, stETHBalance);
    }

    function test_WithdrawZeroAmount() public {
        // First supply some ETH
        uint256 supplyAmount = 1 ether;
        vm.deal(address(this), supplyAmount);
        lidoProvider.supply{value: supplyAmount}(address(0), supplyAmount);

        // Request a withdrawal first
        uint256 withdrawAmount = 0.5 ether;
        lidoProvider.withdraw(address(0), withdrawAmount);

        // Call withdraw with amount 0 to check for finalized withdrawals
        // This should not revert even if no withdrawals are finalized
        lidoProvider.withdraw(address(0), 0);
    }

    function test_WithdrawRevertWhenNotOwner() public {
        vm.prank(address(1));
        vm.expectRevert();
        lidoProvider.withdraw(address(0), 1 ether);
    }

    function test_GetBalance() public {
        // Check balance before supply
        uint256 balanceBefore = lidoProvider.getBalance(address(0));
        assertEq(balanceBefore, 0);

        // Supply ETH
        uint256 supplyAmount = 1 ether;
        vm.deal(address(this), supplyAmount);
        lidoProvider.supply{value: supplyAmount}(address(0), supplyAmount);

        // Check balance after supply
        uint256 balanceAfter = lidoProvider.getBalance(address(0));
        assertGt(balanceAfter, 0);
        assertApproxEqAbs(balanceAfter, supplyAmount, 10);

        // Verify it matches stETH balance
        assertEq(balanceAfter, stETH.balanceOf(address(lidoProvider)));
    }

    function test_GetBalanceAfterWithdraw() public {
        // Supply ETH
        uint256 supplyAmount = 1 ether;
        vm.deal(address(this), supplyAmount);
        lidoProvider.supply{value: supplyAmount}(address(0), supplyAmount);

        uint256 balanceBeforeWithdraw = lidoProvider.getBalance(address(0));

        // Request withdrawal
        uint256 withdrawAmount = balanceBeforeWithdraw / 2;
        lidoProvider.withdraw(address(0), withdrawAmount);

        // Balance should decrease
        uint256 balanceAfterWithdraw = lidoProvider.getBalance(address(0));
        assertLt(balanceAfterWithdraw, balanceBeforeWithdraw);
    }

    function test_MultipleSupplies() public {
        uint256 supplyAmount1 = 0.5 ether;
        uint256 supplyAmount2 = 0.5 ether;

        vm.deal(address(this), supplyAmount1 + supplyAmount2);

        // First supply
        lidoProvider.supply{value: supplyAmount1}(address(0), supplyAmount1);
        uint256 balanceAfterFirst = lidoProvider.getBalance(address(0));

        // Second supply
        lidoProvider.supply{value: supplyAmount2}(address(0), supplyAmount2);
        uint256 balanceAfterSecond = lidoProvider.getBalance(address(0));

        assertGt(balanceAfterSecond, balanceAfterFirst);
    }

    function test_MultipleWithdrawals() public {
        // Supply ETH
        uint256 supplyAmount = 2 ether;
        vm.deal(address(this), supplyAmount);
        lidoProvider.supply{value: supplyAmount}(address(0), supplyAmount);

        uint256 initialBalance = lidoProvider.getBalance(address(0));

        // First withdrawal request
        uint256 withdrawAmount1 = initialBalance / 3;
        lidoProvider.withdraw(address(0), withdrawAmount1);
        uint256 balanceAfterFirst = lidoProvider.getBalance(address(0));
        assertLt(balanceAfterFirst, initialBalance);

        // Second withdrawal request
        uint256 withdrawAmount2 = balanceAfterFirst / 2;
        lidoProvider.withdraw(address(0), withdrawAmount2);
        uint256 balanceAfterSecond = lidoProvider.getBalance(address(0));
        assertLt(balanceAfterSecond, balanceAfterFirst);
    }
}

