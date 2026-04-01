// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {LidoV2Provider} from "../../src/providers/LidoV2Provider.sol";
import {mainnet} from "../../script/addresses.sol";
import {IStETH, IUnstETH} from "../../src/libs/lido/v2/Lido.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {WETHBalanceNotEnough} from "../../src/interfaces/IVault.sol";

/// @dev Simulates Lido's unstETH: marks all requests as finalized and sends ETH on claimWithdrawal
contract MockUnstETHSendsEth {
    uint256 public ethPerClaim;

    constructor(uint256 ethPerClaim_) payable {
        ethPerClaim = ethPerClaim_;
    }

    function getWithdrawalStatus(uint256[] calldata requestIds)
        external
        view
        returns (IUnstETH.WithdrawalRequestStatus[] memory statuses)
    {
        statuses = new IUnstETH.WithdrawalRequestStatus[](requestIds.length);
        for (uint256 i = 0; i < requestIds.length; i++) {
            statuses[i] = IUnstETH.WithdrawalRequestStatus({
                amountOfStETH: ethPerClaim,
                amountOfShares: 0,
                owner: address(this),
                timestamp: block.timestamp,
                isFinalized: true,
                isClaimed: false
            });
        }
    }

    function claimWithdrawal(uint256) external {
        (bool success,) = msg.sender.call{value: ethPerClaim}("");
        require(success, "ETH transfer failed");
    }

    receive() external payable {}
}

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

    function test_Unstake_ResetsApprovalToZero() public {
        uint256 stakeAmount = 1 ether;
        deal(address(weth), address(this), stakeAmount);
        weth.approve(address(lidoProvider), stakeAmount);
        lidoProvider.stake(stakeAmount);

        uint256 unstakeAmount = stETH.balanceOf(address(lidoProvider));
        lidoProvider.unstake(unstakeAmount);

        uint256 remaining = IERC20(address(stETH)).allowance(address(lidoProvider), address(unstETH));
        assertEq(remaining, 0, "approval to unstETH must be 0 after unstake");
    }

    function test_Claim_ReturnWETHToVault() public {
        uint256 claimAmount = 1 ether;
        MockUnstETHSendsEth mockUnstETH = new MockUnstETHSendsEth{value: claimAmount}(claimAmount);
        LidoV2Provider provider = new LidoV2Provider(mainnet.STETH, address(mockUnstETH), mainnet.WETH);
        provider.initialize(address(this));

        uint256 wethBefore = weth.balanceOf(address(this));

        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = 1;
        provider.claim(requestIds);

        assertEq(address(provider).balance, 0, "provider should have 0 ETH after claim");
        assertEq(IERC20(mainnet.WETH).balanceOf(address(provider)), 0, "provider should have 0 WETH after claim");
        assertEq(
            IERC20(mainnet.WETH).balanceOf(address(this)),
            wethBefore + claimAmount,
            "WETH returned to vault after claim"
        );
    }

    function test_Claim_MultipleRequests_ReturnWETHToVault() public {
        uint256 ethPerClaim = 0.5 ether;
        uint256 numRequests = 3;
        uint256 totalEth = ethPerClaim * numRequests;
        MockUnstETHSendsEth mockUnstETH = new MockUnstETHSendsEth{value: totalEth}(ethPerClaim);
        LidoV2Provider provider = new LidoV2Provider(mainnet.STETH, address(mockUnstETH), mainnet.WETH);
        provider.initialize(address(this));

        uint256 wethBefore = weth.balanceOf(address(this));

        uint256[] memory requestIds = new uint256[](numRequests);
        for (uint256 i = 0; i < numRequests; i++) {
            requestIds[i] = i + 1;
        }
        provider.claim(requestIds);

        assertEq(address(provider).balance, 0, "provider should have 0 ETH after claim");
        assertEq(IERC20(mainnet.WETH).balanceOf(address(provider)), 0, "provider should have 0 WETH after claim");
        assertEq(
            IERC20(mainnet.WETH).balanceOf(address(this)),
            wethBefore + totalEth,
            "all WETH returned to vault after claim"
        );
    }

    function test_Claim_emptyUnstakeRequests_doesNotRevert() public {
        lidoProvider.claim(new uint256[](0));
    }

    function test_Claim_multipleRequests_allClaimedAndRemoved() public {
        uint256 amountPerRequest = 0.5 ether;
        uint256 numRequests = 2;

        // Stake extra to account for stETH share/ETH conversion rounding - requesting
        // withdrawals transfers shares out and can leave slightly less than requested
        uint256 totalStake = amountPerRequest * numRequests * 2;
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
        uint256[] memory requestIds = lidoProvider.getUnstakeRequestIds();
        lidoProvider.claim(requestIds);

        uint256[] memory remaining = lidoProvider.getUnstakeRequestIds();
        assertEq(remaining.length, 0, "all claimable requests must be removed");
    }
}

