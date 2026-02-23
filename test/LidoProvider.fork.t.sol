// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import "forge-std/console.sol";
import {Test} from "lib/forge-std/src/Test.sol";
import {LidoV2Provider} from "../src/providers/LidoV2Provider.sol";
import {mainnet} from "../script/addresses.sol";
import {IStETH, IUnstETH} from "../src/libs/Lido.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {WETHBalanceNotEnough} from "../src/interfaces/IVault.sol";

contract TestLidoProviderFork is Test {
    using Address for address;

    LidoV2Provider public lidoProvider;
    IStETH public stETH;
    IUnstETH public unstETH;
    WETH public weth;

    function setUp() public {
        vm.createSelectFork("mainnet");
        lidoProvider = new LidoV2Provider(mainnet.STETH, mainnet.UNSTETH, mainnet.WETH);
        lidoProvider.initialize(address(this));
        stETH = IStETH(mainnet.STETH);
        unstETH = IUnstETH(mainnet.UNSTETH);
        weth = WETH(payable(mainnet.WETH));
    }

    function test_Initialize() public view {
        assertEq(lidoProvider.owner(), address(this));
    }

    function test_InitializeRevertWhenCalledTwice() public {
        LidoV2Provider newProvider = new LidoV2Provider(mainnet.STETH, mainnet.UNSTETH, mainnet.WETH);
        newProvider.initialize(address(this));
        vm.expectRevert();
        newProvider.initialize(address(1));
    }

    function test_Stake() public {
        uint256 stakeAmount = 1 ether;
        deal(address(weth), address(this), stakeAmount);
        weth.approve(address(lidoProvider), stakeAmount);

        uint256 balanceBefore = stETH.balanceOf(address(lidoProvider));
        lidoProvider.stake(stakeAmount);
        uint256 balanceAfter = stETH.balanceOf(address(lidoProvider));
        assertGt(balanceAfter, balanceBefore);
        assertApproxEqAbs(balanceAfter - balanceBefore, stakeAmount, 10);
    }

    function test_StakeRevertWhenWETHBalanceNotEnough() public {
        uint256 stakeAmount = 1 ether;
        deal(address(weth), address(this), stakeAmount);
        weth.approve(address(lidoProvider), stakeAmount);
        vm.expectRevert(WETHBalanceNotEnough.selector);
        lidoProvider.stake(stakeAmount + 1 ether);
    }
}

