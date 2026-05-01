// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {UniswapXProvider} from "provider-contracts/src/providers/UniswapXProvider.sol";
import {mainnet} from "provider-contracts/script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {OrderNotExpired} from "provider-contracts/src/interfaces/IIntentProvider.sol";

contract TestUniswapXProviderFork is Test {
    using SafeERC20 for IERC20;

    UniswapXProvider public uniswapXProvider;
    bytes4 constant MAGICVALUE = 0x1626ba7e;

    function setUp() public {
        vm.createSelectFork("mainnet");
        uniswapXProvider = new UniswapXProvider(mainnet.UNISWAPX_REACTOR, mainnet.PERMIT2);
        uniswapXProvider.initialize(address(this));
    }

    function test_Initialize() public view {
        assertEq(uniswapXProvider.owner(), address(this));
        assertEq(uniswapXProvider.reactor(), mainnet.UNISWAPX_REACTOR);
        assertEq(uniswapXProvider.permit2(), mainnet.PERMIT2);
    }

    function test_EIP1271_IsValidSignature_ApprovedHash() public {
        bytes32 hash = keccak256("test order hash");
        uniswapXProvider.approveHash(hash);

        bytes4 result = uniswapXProvider.isValidSignature(hash, "");
        assertEq(result, MAGICVALUE);
    }

    function test_EIP1271_IsValidSignature_UnapprovedHash() public view {
        bytes32 hash = keccak256("unapproved hash");

        bytes4 result = uniswapXProvider.isValidSignature(hash, "");
        assertTrue(result != MAGICVALUE);
    }

    function test_EIP1271_RevokeHash() public {
        bytes32 hash = keccak256("revocable hash");
        uniswapXProvider.approveHash(hash);
        assertTrue(uniswapXProvider.approvedHashes(address(this), hash));

        uniswapXProvider.revokeHash(hash);
        assertFalse(uniswapXProvider.approvedHashes(address(this), hash));

        bytes4 result = uniswapXProvider.isValidSignature(hash, "");
        assertTrue(result != MAGICVALUE);
    }

    function test_CancelTrade() public {
        bytes32 hash = keccak256("trade to cancel");
        uniswapXProvider.approveHash(hash);
        assertTrue(uniswapXProvider.approvedHashes(address(this), hash));

        uniswapXProvider.cancelTrade(abi.encode(hash));
        assertFalse(uniswapXProvider.approvedHashes(address(this), hash));

        bytes4 result = uniswapXProvider.isValidSignature(hash, "");
        assertTrue(result != MAGICVALUE);
    }

    function test_Swap_ApprovesHashAndPermit2() public {
        uint256 sellAmount = 1000 * 1e6;
        uint256 buyAmountMin = 1e15;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes32 hashToApprove = keccak256("permit2 witness hash");

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(uniswapXProvider), sellAmount);

        bytes memory swapData =
            abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), buyAmountMin, validTo, hashToApprove);

        uniswapXProvider.trade(swapData);

        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(uniswapXProvider)), sellAmount);
        assertTrue(uniswapXProvider.approvedHashes(address(this), hashToApprove));
        assertEq(IERC20(address(mainnet.USDC)).allowance(address(uniswapXProvider), mainnet.PERMIT2), sellAmount);

        uniswapXProvider.cancelTrade(abi.encode(hashToApprove));
        assertEq(
            IERC20(address(mainnet.USDC)).allowance(address(uniswapXProvider), mainnet.PERMIT2),
            0,
            "Permit2 allowance revoked after cancel"
        );
    }

    function test_CancelTrade_ReturnsSellTokensToVault() public {
        uint256 sellAmount = 1000 * 1e6;
        uint256 buyAmountMin = 1e15;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes32 hashToApprove = keccak256("permit2 witness hash");

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(uniswapXProvider), sellAmount);

        bytes memory swapData =
            abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), buyAmountMin, validTo, hashToApprove);
        uniswapXProvider.trade(swapData);

        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(uniswapXProvider)), sellAmount);
        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(this)), 0);

        uniswapXProvider.cancelTrade(abi.encode(hashToApprove));

        assertEq(
            IERC20(address(mainnet.USDC)).balanceOf(address(uniswapXProvider)),
            0,
            "provider balance should be 0 after cancel"
        );
        assertEq(
            IERC20(address(mainnet.USDC)).balanceOf(address(this)),
            sellAmount,
            "sell tokens returned to vault after cancel"
        );
    }

    function test_CancelTrade_ReturnsSellTokensToVault_WithExplicitToken() public {
        uint256 sellAmount = 1000 * 1e6;
        uint256 buyAmountMin = 1e15;

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(uniswapXProvider), sellAmount);

        bytes memory swapData = abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), buyAmountMin);
        uniswapXProvider.trade(swapData);

        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(uniswapXProvider)), sellAmount);
        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(this)), 0);

        uniswapXProvider.cancelTrade(abi.encode(bytes32(0), address(mainnet.USDC)));

        assertEq(
            IERC20(address(mainnet.USDC)).balanceOf(address(uniswapXProvider)),
            0,
            "provider balance should be 0 after cancel"
        );
        assertEq(
            IERC20(address(mainnet.USDC)).balanceOf(address(this)),
            sellAmount,
            "sell tokens returned to vault after cancel"
        );
    }

    function test_CleanExpiredOrders_RevertsIfNotExpired() public {
        uint256 sellAmount = 1000e6;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes32 hashToApprove = keccak256("permit2 witness hash");

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(uniswapXProvider), sellAmount);
        uniswapXProvider.trade(
            abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), 1e15, validTo, hashToApprove)
        );

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = hashToApprove;
        vm.expectRevert(OrderNotExpired.selector);
        uniswapXProvider.cleanExpiredOrders(hashes);
    }

    function test_CleanExpiredOrders_PermissionlesslyCleanupAfterExpiry() public {
        uint256 sellAmount = 1000e6;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes32 hashToApprove = keccak256("permit2 witness hash");

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(uniswapXProvider), sellAmount);
        uniswapXProvider.trade(
            abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), 1e15, validTo, hashToApprove)
        );

        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(uniswapXProvider)), sellAmount);
        assertEq(IERC20(address(mainnet.USDC)).allowance(address(uniswapXProvider), mainnet.PERMIT2), sellAmount);

        vm.warp(validTo + 1);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = hashToApprove;
        vm.prank(address(0xdead));
        uniswapXProvider.cleanExpiredOrders(hashes);

        assertEq(
            IERC20(address(mainnet.USDC)).allowance(address(uniswapXProvider), mainnet.PERMIT2),
            0,
            "permit2 approval must be 0 after clean"
        );
        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(uniswapXProvider)), 0, "provider must hold no tokens");
        assertEq(
            IERC20(address(mainnet.USDC)).balanceOf(address(this)), sellAmount, "tokens returned to vault after clean"
        );
        assertFalse(uniswapXProvider.approvedHashes(address(this), hashToApprove), "hash must be revoked");
    }

    function test_CleanExpiredOrders_DoesNotBreakConcurrentOrder() public {
        uint256 sellAmount1 = 1000e6;
        uint256 sellAmount2 = 500e6;
        uint32 validTo1 = uint32(block.timestamp + 3600);
        uint32 validTo2 = uint32(block.timestamp + 7200);
        bytes32 hash1 = keccak256("order 1 - expires first");
        bytes32 hash2 = keccak256("order 2 - still valid");

        deal(address(mainnet.USDC), address(this), sellAmount1 + sellAmount2);
        IERC20(address(mainnet.USDC)).safeApprove(address(uniswapXProvider), sellAmount1 + sellAmount2);

        uniswapXProvider.trade(
            abi.encode(address(mainnet.USDC), sellAmount1, address(mainnet.WETH), 1e15, validTo1, hash1)
        );
        uniswapXProvider.trade(
            abi.encode(address(mainnet.USDC), sellAmount2, address(mainnet.WETH), 1e15, validTo2, hash2)
        );

        assertEq(
            IERC20(address(mainnet.USDC)).allowance(address(uniswapXProvider), mainnet.PERMIT2),
            sellAmount1 + sellAmount2,
            "combined allowance after two trades"
        );

        vm.warp(validTo1 + 1);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = hash1;
        uniswapXProvider.cleanExpiredOrders(hashes);

        assertEq(
            IERC20(address(mainnet.USDC)).allowance(address(uniswapXProvider), mainnet.PERMIT2),
            sellAmount2,
            "only expired order's allowance removed; live order's allowance preserved"
        );
        assertTrue(uniswapXProvider.approvedHashes(address(this), hash2), "live order hash still approved");
        assertFalse(uniswapXProvider.approvedHashes(address(this), hash1), "expired order hash revoked");
    }

    function test_Swap_WithoutHashToApprove() public {
        uint256 sellAmount = 1000 * 1e6;
        uint256 buyAmountMin = 1e15;

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(uniswapXProvider), sellAmount);

        bytes memory swapData = abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), buyAmountMin);

        uniswapXProvider.trade(swapData);

        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(uniswapXProvider)), sellAmount);
        assertEq(IERC20(address(mainnet.USDC)).allowance(address(uniswapXProvider), mainnet.PERMIT2), sellAmount);

        uniswapXProvider.cancelTrade(abi.encode(bytes32(0), address(mainnet.USDC)));
        assertEq(
            IERC20(address(mainnet.USDC)).allowance(address(uniswapXProvider), mainnet.PERMIT2),
            0,
            "Permit2 allowance revoked when canceling without stored hash"
        );
    }
}
