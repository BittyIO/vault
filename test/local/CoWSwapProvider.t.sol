// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {CoWSwapProvider} from "../../src/providers/CoWSwapProvider.sol";
import {GPv2Order} from "../../src/libs/cow/GPv2Order.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {OrderNotExpired} from "../../src/interfaces/IIntentProvider.sol";

contract MockSettlement {
    bytes32 public constant DOMAIN_SEP = keccak256("mock-cow-domain");

    function domainSeparator() external pure returns (bytes32) {
        return DOMAIN_SEP;
    }

    function setPreSignature(bytes calldata, bool) external {}
}

contract CoWSwapProviderTest is Test {
    CoWSwapProvider provider;
    MockSettlement settlement;
    MockERC20 usdc;
    MockERC20 dai;

    address owner = makeAddr("owner");
    address attacker = makeAddr("attacker");
    address relayer = makeAddr("relayer");

    bytes4 constant MAGICVALUE = 0x1626ba7e;

    function setUp() public {
        settlement = new MockSettlement();
        usdc = new MockERC20("USDC", "USDC", 6);
        dai = new MockERC20("DAI", "DAI", 18);
        provider = new CoWSwapProvider(address(settlement), relayer);
        provider.initialize(owner);
    }

    function _tradeDigest(uint32 validTo) internal returns (bytes32) {
        usdc.mint(owner, 1000e6);
        vm.startPrank(owner);
        usdc.approve(address(provider), 1000e6);
        provider.trade(abi.encode(address(usdc), uint256(1000e6), address(dai), uint256(900e6), validTo, true));
        vm.stopPrank();

        return GPv2Order.hash(
            GPv2Order.Data({
                sellToken: IERC20(address(usdc)),
                buyToken: IERC20(address(dai)),
                receiver: owner,
                sellAmount: 1000e6,
                buyAmount: 900e6,
                validTo: validTo,
                appData: bytes32(0),
                feeAmount: 0,
                kind: GPv2Order.KIND_SELL,
                partiallyFillable: false,
                sellTokenBalance: GPv2Order.BALANCE_ERC20,
                buyTokenBalance: GPv2Order.BALANCE_ERC20
            }),
            settlement.domainSeparator()
        );
    }

    function test_cleanExpiredOrders_RevertsWhenDigestNeverRegistered() public {
        bytes32[] memory digests = new bytes32[](1);
        digests[0] = keccak256("unknown digest");

        vm.expectRevert(OrderNotExpired.selector);
        provider.cleanExpiredOrders(digests);
    }

    function test_cleanExpiredOrders_RevertsForApproveOrderDigest_NoValidToStored() public {
        bytes32 digest = keccak256("eip1271 order");
        vm.prank(owner);
        provider.approveOrderDigest(digest);

        bytes32[] memory digests = new bytes32[](1);
        digests[0] = digest;

        vm.expectRevert(OrderNotExpired.selector);
        provider.cleanExpiredOrders(digests);

        assertEq(provider.isValidSignature(digest, ""), MAGICVALUE, "order must remain live");
    }

    function test_cleanExpiredOrders_RevertsWhenOrderStillLive() public {
        bytes32 digest = _tradeDigest(uint32(block.timestamp + 3600));

        bytes32[] memory digests = new bytes32[](1);
        digests[0] = digest;

        vm.expectRevert(OrderNotExpired.selector);
        provider.cleanExpiredOrders(digests);
    }

    function test_cleanExpiredOrders_RevertsForZeroValidToTrade() public {
        bytes32 digest = _tradeDigest(0);

        bytes32[] memory digests = new bytes32[](1);
        digests[0] = digest;

        vm.expectRevert(OrderNotExpired.selector);
        provider.cleanExpiredOrders(digests);
    }

    function test_cleanExpiredOrders_SucceedsAfterExpiry() public {
        bytes32 digest = _tradeDigest(uint32(block.timestamp + 1));
        vm.warp(block.timestamp + 2);

        bytes32[] memory digests = new bytes32[](1);
        digests[0] = digest;
        provider.cleanExpiredOrders(digests);

        assertEq(provider.isValidSignature(digest, ""), bytes4(0xffffffff));
    }

    function test_cleanExpiredOrders_ReturnsTokensToOwnerOnExpiry() public {
        bytes32 digest = _tradeDigest(uint32(block.timestamp + 1));
        vm.warp(block.timestamp + 2);

        bytes32[] memory digests = new bytes32[](1);
        digests[0] = digest;
        provider.cleanExpiredOrders(digests);

        assertEq(usdc.balanceOf(address(provider)), 0);
        assertEq(usdc.balanceOf(owner), 1000e6);
    }

    function test_attack_KillLiveEIP1271Order_Reverts() public {
        bytes32 liveDigest = keccak256(abi.encode("live CoW order", block.timestamp + 3600));
        vm.prank(owner);
        provider.approveOrderDigest(liveDigest);

        bytes32[] memory digests = new bytes32[](1);
        digests[0] = liveDigest;

        vm.prank(attacker);
        vm.expectRevert(OrderNotExpired.selector);
        provider.cleanExpiredOrders(digests);

        assertEq(provider.isValidSignature(liveDigest, ""), MAGICVALUE, "order must still be live");
    }

    function test_attack_KillMultipleLiveOrders_Reverts() public {
        bytes32 digest1 = keccak256("order batch A");
        bytes32 digest2 = keccak256("order batch B");
        bytes32 digest3 = keccak256("order batch C");

        vm.startPrank(owner);
        provider.approveOrderDigest(digest1);
        provider.approveOrderDigest(digest2);
        provider.approveOrderDigest(digest3);
        vm.stopPrank();

        bytes32[] memory digests = new bytes32[](3);
        digests[0] = digest1;
        digests[1] = digest2;
        digests[2] = digest3;

        vm.prank(attacker);
        vm.expectRevert(OrderNotExpired.selector);
        provider.cleanExpiredOrders(digests);

        assertEq(provider.isValidSignature(digest1, ""), MAGICVALUE);
        assertEq(provider.isValidSignature(digest2, ""), MAGICVALUE);
        assertEq(provider.isValidSignature(digest3, ""), MAGICVALUE);
    }

    function test_attack_ForceCancelZeroValidToTrade_Reverts() public {
        usdc.mint(owner, 1000e6);
        vm.startPrank(owner);
        usdc.approve(address(provider), 1000e6);
        provider.trade(abi.encode(address(usdc), uint256(1000e6), address(dai), uint256(900e6), uint32(0), true));
        vm.stopPrank();

        bytes32 digest = GPv2Order.hash(
            GPv2Order.Data({
                sellToken: IERC20(address(usdc)),
                buyToken: IERC20(address(dai)),
                receiver: owner,
                sellAmount: 1000e6,
                buyAmount: 900e6,
                validTo: 0,
                appData: bytes32(0),
                feeAmount: 0,
                kind: GPv2Order.KIND_SELL,
                partiallyFillable: false,
                sellTokenBalance: GPv2Order.BALANCE_ERC20,
                buyTokenBalance: GPv2Order.BALANCE_ERC20
            }),
            settlement.domainSeparator()
        );

        bytes32[] memory digests = new bytes32[](1);
        digests[0] = digest;

        vm.prank(attacker);
        vm.expectRevert(OrderNotExpired.selector);
        provider.cleanExpiredOrders(digests);
    }

    function test_revokeApprovals_SkipsTokenWithZeroAllowance() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(dai);

        vm.prank(owner);
        provider.revokeApprovals(tokens);
    }

    function test_revokeApprovals_MixedAllowances_SkipsZero() public {
        _tradeDigest(uint32(block.timestamp + 3600));
        assertGt(IERC20(address(usdc)).allowance(address(provider), relayer), 0);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(dai);

        vm.prank(owner);
        provider.revokeApprovals(tokens);

        assertEq(IERC20(address(usdc)).allowance(address(provider), relayer), 0);
    }

    function test_cancelTrade_DecreasesAllowanceByOrderAmountOnly() public {
        uint32 validTo1 = uint32(block.timestamp + 3600);
        uint32 validTo2 = uint32(block.timestamp + 7200);
        bytes32 digest1 = _tradeDigest(validTo1);
        bytes32 digest2 = _tradeDigest(validTo2);

        assertEq(IERC20(address(usdc)).allowance(address(provider), relayer), 2000e6);

        vm.prank(owner);
        provider.cancelTrade(abi.encode(digest1, validTo1));

        assertEq(IERC20(address(usdc)).allowance(address(provider), relayer), 1000e6);
    }
}
