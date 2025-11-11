// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {AssetManager} from "../src/AssetManager.sol";
import {ITrust} from "../src/interfaces/ITrust.sol";
import {PermissionController} from "../src/PermissionController.sol";
import {mainnet} from "../script/addresses.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {console} from "lib/forge-std/src/console.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {AssetType, InvalidAssetType, AssetAlreadySet} from "../src/AssetManager.sol";
import {IPoolDataProvider} from "../src/libs/Aave.sol";

contract TestAssetManager is Test, AssetManager {
    using SafeERC20 for IERC20;
    using Address for address;
    IPoolDataProvider public poolDataProvider;

    function setUp() public initializer {
        vm.createSelectFork("mainnet");
        initialize(
            address(mainnet.WETH),
            address(mainnet.WBTC),
            address(mainnet.USDT),
            address(mainnet.USDC),
            address(mainnet.AAVE_V3),
            address(mainnet.UNISWAP_V4_ROUTER)
        );
        poolDataProvider = IPoolDataProvider(mainnet.POOL_DATA_PROVIDER);
    }

    function addWethToAddress(address to, uint256 amount) public {
        vm.deal(to, amount);
        vm.prank(to);
        Address.sendValue(payable(mainnet.WETH), amount);
    }

    function test_Supply() public {
        addWethToAddress(address(this), 1 ether);
        uint256 balanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        _supply(address(mainnet.WETH), 1 ether);

        uint256 balanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertEq(balanceAfter, balanceBefore - 1 ether);

        (uint256 currentATokenBalance,,,,,,,,) =
            poolDataProvider.getUserReserveData(address(mainnet.WETH), address(this));
        // Aave may have small rounding differences, allow up to 10 wei difference
        assertApproxEqAbs(currentATokenBalance, 1 ether, 10);
    }

    function test_Withdraw() public {
        addWethToAddress(address(this), 1 ether);
        _supply(address(mainnet.WETH), 1 ether);
        uint256 balanceBefore = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        (uint256 aTokenBalance,,,,,,,,) = poolDataProvider.getUserReserveData(address(mainnet.WETH), address(this));
        _withdraw(address(mainnet.WETH), aTokenBalance);
        uint256 balanceAfter = IERC20(address(mainnet.WETH)).balanceOf(address(this));
        assertApproxEqAbs(balanceAfter, balanceBefore + 1 ether, 1);
    }
}
