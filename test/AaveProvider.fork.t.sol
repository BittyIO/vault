// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {AaveV3Provider} from "../src/providers/AaveV3Provider.sol";
import {mainnet} from "../script/addresses.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {IPoolDataProvider} from "../src/libs/Aave.sol";

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

    function test_GetBalance() public {
        uint256 balanceBefore = aaveProvider.getLendingBalance(address(mainnet.WETH));
        assertEq(balanceBefore, 0);

        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProvider), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        aaveProvider.supply(address(mainnet.WETH), 1 ether);

        uint256 balanceAfter = aaveProvider.getLendingBalance(address(mainnet.WETH));
        assertApproxEqAbs(balanceAfter, 1 ether, 10);

        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(aaveProvider));
        assertEq(balanceAfter, currentATokenBalance);
    }

    function test_SupplyMultipleAssets() public {
        IERC20(address(mainnet.WETH)).safeApprove(address(aaveProvider), 1 ether);
        deal(address(mainnet.WETH), address(this), 1 ether);
        aaveProvider.supply(address(mainnet.WETH), 1 ether);

        uint256 wethBalance = aaveProvider.getLendingBalance(address(mainnet.WETH));
        assertApproxEqAbs(wethBalance, 1 ether, 10);

        deal(address(mainnet.USDC), address(this), 1000e6);
        IERC20(address(mainnet.USDC)).safeApprove(address(aaveProvider), 1000e6);
        aaveProvider.supply(address(mainnet.USDC), 1000e6);

        uint256 usdcBalance = aaveProvider.getLendingBalance(address(mainnet.USDC));
        assertApproxEqAbs(usdcBalance, 1000e6, 10);
    }
}

