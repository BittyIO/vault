// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import "forge-std/console.sol";
import {Test} from "lib/forge-std/src/Test.sol";
import {LidoV2Provider} from "../../src/providers/LidoV2Provider.sol";
import {mainnet} from "../../script/addresses.sol";
import {IStETH, IUnstETH} from "../../src/libs/lido/v2/Lido.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {WETHBalanceNotEnough} from "../../src/interfaces/IVault.sol";

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

    function test_Claim_emptyUnstakeRequests_doesNotRevert() public {
        lidoProvider.claim();
    }

    function test_Claim_multipleRequests_allClaimedAndRemoved() public {
        uint256 amountPerRequest = 0.5 ether;
        uint256 numRequests = 2;

        uint256 totalStake = amountPerRequest * numRequests;
        deal(address(weth), address(this), totalStake);
        weth.approve(address(lidoProvider), totalStake);
        lidoProvider.stake(totalStake);

        for (uint256 i = 0; i < numRequests; i++) {
            lidoProvider.unstake(amountPerRequest);
        }

        uint256[] memory ids = lidoProvider.getUnstakeRequestIds();
        assertEq(ids.length, numRequests, "all unstake requests should be tracked");

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];

            uint256[] memory oneId = new uint256[](1);
            oneId[0] = id;

            IUnstETH.WithdrawalRequestStatus[] memory statuses = new IUnstETH.WithdrawalRequestStatus[](1);
            statuses[0] = IUnstETH.WithdrawalRequestStatus({
                amountOfStETH: amountPerRequest,
                amountOfShares: 0,
                owner: address(lidoProvider),
                timestamp: block.timestamp,
                isFinalized: true,
                isClaimed: false
            });

            vm.mockCall(
                address(unstETH),
                abi.encodeWithSelector(IUnstETH.getWithdrawalStatus.selector, oneId),
                abi.encode(statuses)
            );

            vm.mockCall(address(unstETH), abi.encodeWithSelector(IUnstETH.claimWithdrawal.selector, id), "");
        }

        lidoProvider.claim();

        uint256[] memory remaining = lidoProvider.getUnstakeRequestIds();
        assertEq(remaining.length, 0, "all claimable requests must be removed");
    }
}

