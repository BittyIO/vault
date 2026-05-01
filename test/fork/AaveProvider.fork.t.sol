// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {AaveV3Provider} from "provider-contracts/src/providers/AaveV3Provider.sol";
import {mainnet} from "provider-contracts/script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {IAaveV3, IAavePool, IPoolDataProvider} from "provider-contracts/src/libs/aave/v3/Aave.sol";

contract TestAaveProviderFork is Test {
    using SafeERC20 for IERC20;
    using Address for address;

    AaveV3Provider public aaveProvider;
    IPoolDataProvider public poolDataProvider;

    function setUp() public {
        vm.createSelectFork("mainnet");
        aaveProvider = new AaveV3Provider(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER);
        aaveProvider.initialize(address(this));
        poolDataProvider = IPoolDataProvider(mainnet.POOL_DATA_PROVIDER);
    }

    function test_Supply() public {
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProvider), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        uint256 balanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(this));

        aaveProvider.supply(address(mainnet.WETH), 1 ether);

        uint256 balanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertEq(balanceAfter, balanceBefore - 1 ether);

        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProvider));
        assertApproxEqAbs(currentATokenBalance, 1 ether, 10);
    }

    function test_Withdraw() public {
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProvider), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        uint256 balanceBeforeSupply = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        aaveProvider.supply(address(mainnet.WETH), 1 ether);

        (uint256 aTokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProvider));

        uint256 aaveProviderBalanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(aaveProvider));
        assertEq(aaveProviderBalanceBefore, 0);

        aaveProvider.withdraw(address(mainnet.WETH), aTokenBalance);

        uint256 aaveProviderBalanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(aaveProvider));
        assertEq(aaveProviderBalanceAfter, 0);

        uint256 balanceAfterWithdraw = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertApproxEqAbs(balanceAfterWithdraw, balanceBeforeSupply, 5);

        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProvider));
        assertEq(currentATokenBalance, 0);
    }

    function test_Withdraw_UsesActualReturnedAmountNotInput() public {
        address asset = address(mainnet.WETH);
        uint256 requestAmount = 1000e18;
        // Aave returns less than requested for rounding or liquidity reasons
        uint256 mockReturnedAmount = 999e18;

        IAavePool pool = IAaveV3(mainnet.AAVE_V3).getPool();

        deal(asset, address(aaveProvider), mockReturnedAmount);

        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(IAavePool.withdraw.selector, asset, requestAmount, address(aaveProvider)),
            abi.encode(mockReturnedAmount)
        );

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        aaveProvider.withdraw(asset, requestAmount);
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));

        assertEq(balanceAfter - balanceBefore, mockReturnedAmount, "Must transfer actual returned amount, not input");
    }

    function test_GetBalance() public {
        uint256 balanceBefore = aaveProvider.getSuppliedBalance(address(mainnet.WETH));
        assertEq(balanceBefore, 0);

        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProvider), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        aaveProvider.supply(address(mainnet.WETH), 1 ether);

        uint256 balanceAfter = aaveProvider.getSuppliedBalance(address(mainnet.WETH));
        assertApproxEqAbs(balanceAfter, 1 ether, 10);

        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProvider));
        assertEq(balanceAfter, currentATokenBalance);
    }

    function test_Supply_ResetsApprovalToZero() public {
        deal(address(mainnet.WETH), address(this), 1 ether);
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProvider), 1 ether);

        aaveProvider.supply(address(mainnet.WETH), 1 ether);

        address pool = address(IAaveV3(mainnet.AAVE_V3).getPool());
        uint256 remaining = IERC20(address(mainnet.WETH)).allowance(address(aaveProvider), pool);
        assertEq(remaining, 0, "approval to Aave pool must be 0 after supply");
    }

    function test_SupplyMultipleAssets() public {
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProvider), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        aaveProvider.supply(address(mainnet.WETH), 1 ether);

        uint256 wethBalance = aaveProvider.getSuppliedBalance(address(mainnet.WETH));
        assertApproxEqAbs(wethBalance, 1 ether, 10);

        deal(address(mainnet.USDC), address(this), 1000e6);
        IERC20(address(mainnet.USDC)).safeApprove(address(aaveProvider), 1000e6);
        aaveProvider.supply(address(mainnet.USDC), 1000e6);

        uint256 usdcBalance = aaveProvider.getSuppliedBalance(address(mainnet.USDC));
        assertApproxEqAbs(usdcBalance, 1000e6, 10);
    }
}

