// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {CoWSwapProvider} from "../../src/providers/CoWSwapProvider.sol";
import {GPv2Order} from "../../src/libs/cow/GPv2Order.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {
    OrderNotExpired,
    TwapNotFound,
    TwapCompleted,
    TwapIntervalNotElapsed,
    TwapInvalidParams
} from "../../src/interfaces/IIntentProvider.sol";

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
        _tradeDigest(validTo2);

        assertEq(IERC20(address(usdc)).allowance(address(provider), relayer), 2000e6);

        vm.prank(owner);
        provider.cancelTrade(abi.encode(digest1, validTo1));

        assertEq(IERC20(address(usdc)).allowance(address(provider), relayer), 1000e6);
    }

    function test_cancelTrade_ReturnsOnlyOrderSellAmountWhenBalanceExceedsOneOrder() public {
        uint32 validTo1 = uint32(block.timestamp + 3600);
        uint32 validTo2 = uint32(block.timestamp + 7200);
        bytes32 digest1 = _tradeDigest(validTo1);
        _tradeDigest(validTo2);

        assertEq(usdc.balanceOf(address(provider)), 2000e6);
        assertEq(usdc.balanceOf(owner), 0);

        vm.prank(owner);
        provider.cancelTrade(abi.encode(digest1, validTo1));

        assertEq(usdc.balanceOf(owner), 1000e6, "only first order's sell amount returned");
        assertEq(usdc.balanceOf(address(provider)), 1000e6, "second order's funds stay on provider");
    }

    function _createData(
        uint256 totalSellAmount,
        uint256 minBuyAmountPerSlice,
        uint32 interval,
        uint32 sliceDuration,
        uint16 numSlices
    ) internal view returns (bytes memory) {
        return abi.encode(
            address(usdc), totalSellAmount, address(dai), minBuyAmountPerSlice, interval, sliceDuration, numSlices
        );
    }

    function _twapId(uint256 total, uint16 numSlices, uint32 interval, uint256 ts) internal view returns (bytes32) {
        return keccak256(abi.encode(owner, address(usdc), address(dai), total, numSlices, interval, ts));
    }

    function _sliceDigest(uint256 sliceAmount, uint256 minBuy, uint32 validTo) internal view returns (bytes32) {
        return GPv2Order.hash(
            GPv2Order.Data({
                sellToken: IERC20(address(usdc)),
                buyToken: IERC20(address(dai)),
                receiver: owner,
                sellAmount: sliceAmount,
                buyAmount: minBuy,
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

    function test_twapTrade_CreatesNewTwap() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        uint32 interval = 3600;
        uint32 sliceDuration = 1800;
        uint256 ts = block.timestamp;

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, interval, sliceDuration, numSlices));
        vm.stopPrank();

        bytes32 id = _twapId(total, numSlices, interval, ts);
        (
            address sellToken,
            address buyToken,
            uint256 sliceAmount,
            uint256 remainingAmount,
            uint256 minBuy,
            uint32 storedInterval,
            uint32 storedDuration,
            uint32 lastExec,
            uint16 storedNumSlices,
            uint16 executedSlices
        ) = provider.twapOrders(id);

        assertEq(sellToken, address(usdc));
        assertEq(buyToken, address(dai));
        assertEq(sliceAmount, total / numSlices);
        assertEq(remainingAmount, total - total / numSlices);
        assertEq(storedInterval, interval);
        assertEq(storedNumSlices, numSlices);
        assertEq(executedSlices, 1);
        assertEq(lastExec, uint32(ts));
    }

    function test_twapTrade_TransfersTokensAndGrantsSliceAllowance() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        uint256 sliceAmount = total / numSlices;

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, 3600, 1800, numSlices));
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(provider)), total, "all tokens on provider");
        assertEq(IERC20(address(usdc)).allowance(address(provider), relayer), sliceAmount, "only slice 1 approved");
    }

    function test_twapTrade_ApprovesFirstSliceDigest() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        uint32 sliceDuration = 1800;
        uint32 validTo = uint32(block.timestamp + sliceDuration);
        uint256 sliceAmount = total / numSlices;

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, 3600, sliceDuration, numSlices));
        vm.stopPrank();

        bytes32 digest = _sliceDigest(sliceAmount, 0, validTo);
        assertEq(provider.isValidSignature(digest, ""), MAGICVALUE, "first slice digest approved");
    }

    function test_twapTrade_EmitsTwapCreatedEvent() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        uint32 interval = 3600;
        uint256 ts = block.timestamp;

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);

        bytes32 id = _twapId(total, numSlices, interval, ts);
        vm.expectEmit(true, false, false, true);
        emit CoWSwapProvider.TwapCreated(id, address(usdc), address(dai), total, numSlices, interval);
        provider.twapTrade(_createData(total, 0, interval, 1800, numSlices));
        vm.stopPrank();
    }

    function test_twapTrade_ExecutesNextSlice() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        uint32 interval = 3600;
        uint32 sliceDuration = 1800;
        uint256 ts = block.timestamp;
        uint256 sliceAmount = total / numSlices;

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, interval, sliceDuration, numSlices));
        vm.stopPrank();

        bytes32 id = _twapId(total, numSlices, interval, ts);

        vm.warp(block.timestamp + interval);

        vm.prank(owner);
        provider.twapTrade(abi.encode(id));

        (,,, uint256 remainingAmount,,,,, uint16 storedNumSlices, uint16 executedSlices) = provider.twapOrders(id);
        assertEq(executedSlices, 2);
        assertEq(remainingAmount, total - 2 * sliceAmount);
        assertEq(IERC20(address(usdc)).allowance(address(provider), relayer), 2 * sliceAmount, "two slices approved");
    }

    function test_twapTrade_LastSliceGetsRemainder() public {
        uint256 total = 1000e6 + 1;
        uint16 numSlices = 4;
        uint32 interval = 3600;
        uint32 sliceDuration = 1800;
        uint256 ts = block.timestamp;
        uint256 sliceAmount = total / numSlices;
        uint256 remainder = total - sliceAmount * (numSlices - 1);

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, interval, sliceDuration, numSlices));
        vm.stopPrank();

        bytes32 id = _twapId(total, numSlices, interval, ts);

        for (uint256 i = 0; i < 2; i++) {
            vm.warp(block.timestamp + interval);
            vm.prank(owner);
            provider.twapTrade(abi.encode(id));
        }

        uint32 lastSliceValidTo = uint32(block.timestamp + interval + sliceDuration);
        vm.warp(block.timestamp + interval);
        vm.prank(owner);
        provider.twapTrade(abi.encode(id));

        bytes32 lastDigest = _sliceDigest(remainder, 0, lastSliceValidTo);
        assertEq(provider.isValidSignature(lastDigest, ""), MAGICVALUE, "last slice digest approved");

        (,,, uint256 remainingAfter,,,,, uint16 storedNumSlices, uint16 executedSlices) = provider.twapOrders(id);
        assertEq(executedSlices, numSlices);
        assertEq(remainingAfter, 0);
    }

    function test_twapTrade_RevertsIfIntervalNotElapsed() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        uint32 interval = 3600;
        uint256 ts = block.timestamp;

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, interval, 1800, numSlices));
        vm.stopPrank();

        bytes32 id = _twapId(total, numSlices, interval, ts);

        vm.prank(owner);
        vm.expectRevert(TwapIntervalNotElapsed.selector);
        provider.twapTrade(abi.encode(id));
    }

    function test_twapTrade_RevertsIfCompleted() public {
        uint256 total = 600e6;
        uint16 numSlices = 2;
        uint32 interval = 3600;
        uint32 sliceDuration = 1800;
        uint256 ts = block.timestamp;

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, interval, sliceDuration, numSlices));
        vm.stopPrank();

        bytes32 id = _twapId(total, numSlices, interval, ts);

        vm.warp(block.timestamp + interval);
        vm.prank(owner);
        provider.twapTrade(abi.encode(id));

        vm.warp(block.timestamp + interval);
        vm.prank(owner);
        vm.expectRevert(TwapCompleted.selector);
        provider.twapTrade(abi.encode(id));
    }

    function test_twapTrade_RevertsIfTwapNotFound() public {
        bytes32 badId = keccak256("nonexistent");
        vm.prank(owner);
        vm.expectRevert(TwapNotFound.selector);
        provider.twapTrade(abi.encode(badId));
    }

    function test_twapTrade_RevertsInvalidParams_TooFewSlices() public {
        usdc.mint(owner, 1000e6);
        vm.startPrank(owner);
        usdc.approve(address(provider), 1000e6);
        vm.expectRevert(TwapInvalidParams.selector);
        provider.twapTrade(_createData(1000e6, 0, 3600, 1800, 1));
        vm.stopPrank();
    }

    function test_twapTrade_RevertsInvalidParams_ZeroInterval() public {
        usdc.mint(owner, 1000e6);
        vm.startPrank(owner);
        usdc.approve(address(provider), 1000e6);
        vm.expectRevert(TwapInvalidParams.selector);
        provider.twapTrade(_createData(1000e6, 0, 0, 1800, 4));
        vm.stopPrank();
    }

    function test_twapTrade_RevertsInvalidParams_ZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(TwapInvalidParams.selector);
        provider.twapTrade(_createData(0, 0, 3600, 1800, 4));
    }

    function test_cancelTwap_ReturnsRemainingAmount() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        uint32 interval = 3600;
        uint256 ts = block.timestamp;
        uint256 sliceAmount = total / numSlices;

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, interval, 1800, numSlices));
        vm.stopPrank();

        bytes32 id = _twapId(total, numSlices, interval, ts);

        vm.warp(block.timestamp + interval);
        vm.prank(owner);
        provider.twapTrade(abi.encode(id));

        uint256 expectedRemaining = total - 2 * sliceAmount;

        vm.prank(owner);
        provider.cancelTwap(id);

        assertEq(usdc.balanceOf(owner), expectedRemaining, "unallocated tokens returned");
    }

    function test_cancelTwap_DeletesTwapState() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        uint32 interval = 3600;
        uint256 ts = block.timestamp;

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, interval, 1800, numSlices));
        vm.stopPrank();

        bytes32 id = _twapId(total, numSlices, interval, ts);

        vm.prank(owner);
        provider.cancelTwap(id);

        (,,,,,,,, uint16 storedNumSlices,) = provider.twapOrders(id);
        assertEq(storedNumSlices, 0, "twap state deleted");
    }

    function test_cancelTwap_RevertsIfNotFound() public {
        bytes32 badId = keccak256("no twap here");
        vm.prank(owner);
        vm.expectRevert(TwapNotFound.selector);
        provider.cancelTwap(badId);
    }

    function test_cancelTwap_RevertsIfCalledTwice() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        uint256 ts = block.timestamp;

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, 3600, 1800, numSlices));
        vm.stopPrank();

        bytes32 id = _twapId(total, numSlices, 3600, ts);

        vm.prank(owner);
        provider.cancelTwap(id);

        vm.prank(owner);
        vm.expectRevert(TwapNotFound.selector);
        provider.cancelTwap(id);
    }

    function test_twapSlice_CanBeCancelledViaCancelTrade() public {
        uint256 total = 1000e6;
        uint16 numSlices = 4;
        uint32 sliceDuration = 1800;
        uint32 validTo = uint32(block.timestamp + sliceDuration);
        uint256 sliceAmount = total / numSlices;

        usdc.mint(owner, total);
        vm.startPrank(owner);
        usdc.approve(address(provider), total);
        provider.twapTrade(_createData(total, 0, 3600, sliceDuration, numSlices));
        vm.stopPrank();

        bytes32 digest = _sliceDigest(sliceAmount, 0, validTo);
        assertEq(provider.isValidSignature(digest, ""), MAGICVALUE, "slice active before cancel");

        vm.prank(owner);
        provider.cancelTrade(abi.encode(digest, validTo));

        assertEq(provider.isValidSignature(digest, ""), bytes4(0xffffffff), "slice revoked after cancel");
        assertEq(usdc.balanceOf(owner), sliceAmount, "slice tokens returned");
        assertEq(IERC20(address(usdc)).allowance(address(provider), relayer), 0, "relayer allowance cleared");
    }
}
