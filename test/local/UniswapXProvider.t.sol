// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {UniswapXProvider} from "provider-contracts/src/providers/UniswapXProvider.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {OrderNotExpired} from "provider-contracts/src/interfaces/IIntentProvider.sol";

contract UniswapXProviderTest is Test {
    UniswapXProvider provider;
    MockERC20 usdc;
    MockERC20 dai;

    address owner = makeAddr("owner");
    address permit2 = makeAddr("permit2");

    bytes4 constant MAGICVALUE = 0x1626ba7e;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        dai = new MockERC20("DAI", "DAI", 18);
        provider = new UniswapXProvider(makeAddr("reactor"), permit2);
        provider.initialize(owner);
    }

    function _trade(uint32 validTo, bytes32 hashToApprove) internal {
        usdc.mint(owner, 1000e6);
        vm.startPrank(owner);
        usdc.approve(address(provider), 1000e6);
        bytes memory data =
            abi.encode(address(usdc), uint256(1000e6), address(dai), uint256(900e6), validTo, hashToApprove, true);
        provider.trade(data);
        vm.stopPrank();
    }

    function test_cleanExpiredOrders_RevertsWhenHashNeverRegistered() public {
        bytes32 unknown = keccak256("unknown hash");
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = unknown;

        vm.expectRevert(OrderNotExpired.selector);
        provider.cleanExpiredOrders(hashes);
    }

    function test_cleanExpiredOrders_RevertsForApproveHash_NoValidToStored() public {
        bytes32 hash = keccak256("permit2 witness hash");
        vm.prank(owner);
        provider.approveHash(hash);

        assertEq(provider.isValidSignature(hash, ""), MAGICVALUE, "hash should be approved");

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = hash;

        vm.expectRevert(OrderNotExpired.selector);
        provider.cleanExpiredOrders(hashes);

        assertEq(provider.isValidSignature(hash, ""), MAGICVALUE, "hash must remain approved");
    }

    function test_cleanExpiredOrders_RevertsWhenOrderStillLive() public {
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes32 hash = keccak256("live order hash");
        _trade(validTo, hash);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = hash;

        vm.expectRevert(OrderNotExpired.selector);
        provider.cleanExpiredOrders(hashes);
    }

    function test_cleanExpiredOrders_SucceedsAfterExpiry() public {
        uint32 validTo = uint32(block.timestamp + 1);
        bytes32 hash = keccak256("expiring order hash");
        _trade(validTo, hash);

        vm.warp(block.timestamp + 2);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = hash;

        provider.cleanExpiredOrders(hashes);

        assertEq(provider.isValidSignature(hash, ""), bytes4(0xffffffff), "hash must be cleared");
    }

    function test_cleanExpiredOrders_ReturnsTokensToOwnerOnExpiry() public {
        uint32 validTo = uint32(block.timestamp + 1);
        bytes32 hash = keccak256("expiring order hash");
        _trade(validTo, hash);

        assertEq(usdc.balanceOf(address(provider)), 1000e6);

        vm.warp(block.timestamp + 2);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = hash;
        provider.cleanExpiredOrders(hashes);

        assertEq(usdc.balanceOf(address(provider)), 0);
        assertEq(usdc.balanceOf(owner), 1000e6);
    }

    function test_cleanExpiredOrders_RevertsForZeroValidToTrade() public {
        bytes32 hash = keccak256("zero validTo order");
        _trade(0, hash);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = hash;

        vm.expectRevert(OrderNotExpired.selector);
        provider.cleanExpiredOrders(hashes);
    }

    function test_revokeApprovals_SkipsTokenWithZeroAllowance() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(dai);

        vm.prank(owner);
        provider.revokeApprovals(tokens);
    }

    function test_revokeApprovals_MixedAllowances_SkipsZero() public {
        _trade(uint32(block.timestamp + 3600), keccak256("h"));
        assertGt(IERC20(address(usdc)).allowance(address(provider), permit2), 0);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(dai);

        vm.prank(owner);
        provider.revokeApprovals(tokens);

        assertEq(IERC20(address(usdc)).allowance(address(provider), permit2), 0);
    }

    function test_cancelTrade_DecreasesAllowanceByOrderAmountOnly() public {
        bytes32 hash1 = keccak256("order 1");
        bytes32 hash2 = keccak256("order 2");
        uint32 validTo = uint32(block.timestamp + 3600);
        _trade(validTo, hash1);
        _trade(validTo, hash2);

        assertEq(IERC20(address(usdc)).allowance(address(provider), permit2), 2000e6);

        vm.prank(owner);
        provider.cancelTrade(abi.encode(hash1));

        assertEq(IERC20(address(usdc)).allowance(address(provider), permit2), 1000e6);
    }

    function test_cancelTrade_ReturnsOnlyOrderSellAmountWhenBalanceExceedsOneOrder() public {
        bytes32 hash1 = keccak256("order 1 stacked");
        bytes32 hash2 = keccak256("order 2 stacked");
        uint32 validTo = uint32(block.timestamp + 3600);
        _trade(validTo, hash1);
        _trade(validTo, hash2);

        assertEq(usdc.balanceOf(address(provider)), 2000e6);
        assertEq(usdc.balanceOf(owner), 0);

        vm.prank(owner);
        provider.cancelTrade(abi.encode(hash1));

        assertEq(usdc.balanceOf(owner), 1000e6, "only first order's sell amount returned");
        assertEq(usdc.balanceOf(address(provider)), 1000e6, "second order's funds stay on provider");
    }
}
