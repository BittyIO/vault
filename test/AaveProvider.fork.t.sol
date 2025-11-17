// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {AaveProvider} from "../src/providers/AaveProvider.sol";
import {mainnet} from "../script/addresses.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {IPoolDataProvider} from "../src/libs/Aave.sol";

contract TestAaveProviderFork is Test {
    using SafeERC20 for IERC20;
    using Address for address;

    AaveProvider public aaveProvider;
    IPoolDataProvider public poolDataProvider;

    function setUp() public {
        vm.createSelectFork("mainnet");
        aaveProvider = new AaveProvider(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER);
        aaveProvider.initialize(address(this));
        poolDataProvider = IPoolDataProvider(mainnet.POOL_DATA_PROVIDER);
    }

    function test_Supply() public {
        // Approve AaveProvider to transfer WETH
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProvider), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        uint256 balanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        
        // Now supply from AaveProvider (it will transfer and approve internally)
        aaveProvider.supply(address(mainnet.WETH), 1 ether);

        uint256 balanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertEq(balanceAfter, balanceBefore - 1 ether);

        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProvider));
        // Aave may have small rounding differences, allow up to 10 wei difference
        assertApproxEqAbs(currentATokenBalance, 1 ether, 10);
    }

    function test_Withdraw() public {
        // First supply - approve AaveProvider to transfer WETH
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProvider), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        uint256 balanceBeforeSupply = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        aaveProvider.supply(address(mainnet.WETH), 1 ether);

        // Get aToken balance
        (uint256 aTokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProvider));

        // Check AaveProvider WETH balance before withdraw (should be 0)
        uint256 aaveProviderBalanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(aaveProvider));
        assertEq(aaveProviderBalanceBefore, 0);

        // Withdraw - WETH will be transferred back to msg.sender (this test contract)
        aaveProvider.withdraw(address(mainnet.WETH), aTokenBalance);

        // Check AaveProvider WETH balance after withdraw (should be 0, as it transfers to msg.sender)
        uint256 aaveProviderBalanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(aaveProvider));
        assertEq(aaveProviderBalanceAfter, 0);
        
        // Check that WETH was transferred back to this test contract
        uint256 balanceAfterWithdraw = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertApproxEqAbs(balanceAfterWithdraw, balanceBeforeSupply, 5);

        // Verify aToken balance is now 0
        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProvider));
        assertEq(currentATokenBalance, 0);
    }

    function test_GetBalance() public {
        // Check balance before supply
        uint256 balanceBefore = aaveProvider.getBalance(address(mainnet.WETH));
        assertEq(balanceBefore, 0);

        // Supply - approve AaveProvider to transfer WETH
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProvider), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        aaveProvider.supply(address(mainnet.WETH), 1 ether);

        // Check balance after supply
        uint256 balanceAfter = aaveProvider.getBalance(address(mainnet.WETH));
        assertApproxEqAbs(balanceAfter, 1 ether, 10);

        // Verify it matches poolDataProvider
        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProvider));
        assertEq(balanceAfter, currentATokenBalance);
    }

    function test_SupplyMultipleAssets() public {
        // Test WETH
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProvider), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        aaveProvider.supply(address(mainnet.WETH), 1 ether);

        uint256 wethBalance = aaveProvider.getBalance(address(mainnet.WETH));
        assertApproxEqAbs(wethBalance, 1 ether, 10);

        // Test USDC (need to get some USDC first via deal)
        deal(address(mainnet.USDC), address(this), 1000e6);
        IERC20(address(mainnet.USDC)).safeApprove(address(aaveProvider), 1000e6);
        aaveProvider.supply(address(mainnet.USDC), 1000e6);

        uint256 usdcBalance = aaveProvider.getBalance(address(mainnet.USDC));
        assertApproxEqAbs(usdcBalance, 1000e6, 10);
    }
}

