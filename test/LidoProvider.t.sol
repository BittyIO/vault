// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {LidoProvider} from "../src/providers/LidoProvider.sol";
import {MockStETH} from "./mock/MockStETH.sol";
import {MockUnstETH} from "./mock/MockUnstETH.sol";
import {IStETH, IUnstETH} from "../src/libs/Lido.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract TestLidoProvider is Test {
    LidoProvider public lidoProvider;
    MockStETH public stETH;
    MockUnstETH public unstETH;
    WETH public weth;

    function setUp() public {
        stETH = new MockStETH();
        weth = new WETH();
        unstETH = new MockUnstETH(address(stETH));
        lidoProvider = new LidoProvider(address(stETH), address(unstETH), address(weth));
        lidoProvider.initialize(address(this));
    }

    function test_Initialize() public view {
        assertEq(lidoProvider.owner(), address(this));
        assertEq(address(lidoProvider.stETH()), address(stETH));
        assertEq(address(lidoProvider.unstETH()), address(unstETH));
        assertEq(address(lidoProvider.weth()), address(weth));
    }

    function test_InitializeRevertWhenCalledTwice() public {
        LidoProvider newProvider = new LidoProvider(address(stETH), address(unstETH), address(weth));
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
        // stETH balance should increase
        assertGt(balanceAfter, balanceBefore);
        // Should receive approximately the same amount in stETH (1:1 in mock)
        assertEq(balanceAfter - balanceBefore, supplyAmount);
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

    function test_WithdrawRevertWhenAssetNotZero() public {
        vm.expectRevert(LidoProvider.InvalidAsset.selector);
        lidoProvider.withdraw(address(1), 1 ether);
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
        assertEq(balanceAfter, supplyAmount);

        // Verify it matches stETH balance
        assertEq(balanceAfter, stETH.balanceOf(address(lidoProvider)));
    }

    function test_GetBalanceRevertWhenAssetNotZero() public {
        vm.expectRevert(LidoProvider.InvalidAsset.selector);
        lidoProvider.getBalance(address(1));
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
        assertEq(balanceAfterSecond, supplyAmount1 + supplyAmount2);
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

    function test_GetWithdrawalStatus() public {
        // Supply ETH
        uint256 supplyAmount = 1 ether;
        vm.deal(address(this), supplyAmount);
        lidoProvider.supply{value: supplyAmount}(address(0), supplyAmount);

        // Request withdrawal
        uint256 withdrawAmount = 0.5 ether;
        lidoProvider.withdraw(address(0), withdrawAmount);

        // Get withdrawal status
        IUnstETH.WithdrawalRequestStatus[] memory statuses = lidoProvider.getWithdrawalStatus();
        assertGt(statuses.length, 0);
        assertEq(statuses[0].amountOfStETH, withdrawAmount);
        assertEq(statuses[0].owner, address(lidoProvider));
        assertFalse(statuses[0].isFinalized);
        assertFalse(statuses[0].isClaimed);
    }

    function test_ClaimWithdrawal() public {
        // Supply ETH
        uint256 supplyAmount = 1 ether;
        vm.deal(address(this), supplyAmount);
        lidoProvider.supply{value: supplyAmount}(address(0), supplyAmount);

        // Request withdrawal
        uint256 withdrawAmount = 0.5 ether;
        lidoProvider.withdraw(address(0), withdrawAmount);

        // Get withdrawal request ID
        IUnstETH.WithdrawalRequestStatus[] memory statuses = lidoProvider.getWithdrawalStatus();
        require(statuses.length > 0, "No withdrawal requests");
        assertFalse(statuses[0].isFinalized);

        // Find the request ID (in mock, it starts from 1)
        uint256 requestId = 1;

        // Fund unstETH with ETH to claim (simulating the withdrawal pool)
        vm.deal(address(unstETH), withdrawAmount);

        // Finalize the withdrawal request
        unstETH.finalizeWithdrawal(requestId);

        // Verify status is finalized
        statuses = lidoProvider.getWithdrawalStatus();
        assertTrue(statuses[0].isFinalized);
        assertFalse(statuses[0].isClaimed);

        // Claim withdrawal (should transfer ETH back)
        uint256 balanceBefore = address(this).balance;
        lidoProvider.withdraw(address(0), 0); // This should claim finalized withdrawals
        uint256 balanceAfter = address(this).balance;

        // Balance should increase after claiming
        assertEq(balanceAfter - balanceBefore, withdrawAmount);

        // Verify withdrawal is claimed
        statuses = lidoProvider.getWithdrawalStatus();
        assertEq(statuses.length, 0); // Should be removed after claiming
    }

    function test_Receive() public {
        // Test that the contract can receive ETH
        vm.deal(address(1), 1 ether);
        vm.prank(address(1));
        (bool success,) = address(lidoProvider).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(lidoProvider).balance, 1 ether);
    }

    receive() external payable {}
}

