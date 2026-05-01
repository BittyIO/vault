// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {CoWSwapProvider} from "provider-contracts/src/providers/CoWSwapProvider.sol";
import {GPv2Order} from "provider-contracts/src/libs/cow/GPv2Order.sol";
import {mainnet} from "provider-contracts/script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IGPv2Settlement} from "provider-contracts/src/libs/cow/GPv2Settlement.sol";
import {OrderNotExpired} from "provider-contracts/src/interfaces/IIntentProvider.sol";

contract TestCoWAMMProviderFork is Test {
    using SafeERC20 for IERC20;

    CoWSwapProvider public cowProvider;
    bytes4 constant MAGICVALUE = 0x1626ba7e;

    function setUp() public {
        vm.createSelectFork("mainnet");
        cowProvider = new CoWSwapProvider(mainnet.COW_SETTLEMENT, mainnet.COW_VAULT_RELAYER);
        cowProvider.initialize(address(this));
    }

    function test_Initialize() public view {
        assertEq(cowProvider.owner(), address(this));
        assertEq(address(cowProvider.settlement()), mainnet.COW_SETTLEMENT);
        assertEq(cowProvider.vaultRelayer(), mainnet.COW_VAULT_RELAYER);
    }

    function test_Swap_SetsPreSignature_SellOrder() public {
        uint256 sellAmount = 1000 * 1e6;
        uint256 buyAmountMin = 1e15;
        uint32 validTo = uint32(block.timestamp + 3600);

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(cowProvider), sellAmount);

        bytes memory swapData =
            abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), buyAmountMin, validTo);

        cowProvider.trade(swapData);

        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(cowProvider)), sellAmount);

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(mainnet.USDC)),
            buyToken: IERC20(address(mainnet.WETH)),
            receiver: address(this),
            sellAmount: sellAmount,
            buyAmount: buyAmountMin,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes32 digest = cowProvider.getOrderDigest(order);
        bytes memory orderUid = cowProvider.getOrderUid(order);
        assertEq(orderUid.length, 56);

        assertTrue(cowProvider.approvedOrderDigests(address(this), digest));
    }

    function test_Trade_AllowancePersistsForAsyncSettlement() public {
        uint256 sellAmount = 1000 * 1e6;
        uint256 buyAmountMin = 1e15;
        uint32 validTo = uint32(block.timestamp + 3600);

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(cowProvider), sellAmount);

        bytes memory swapData =
            abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), buyAmountMin, validTo);

        cowProvider.trade(swapData);

        uint256 allowance = IERC20(address(mainnet.USDC)).allowance(address(cowProvider), cowProvider.vaultRelayer());
        assertEq(allowance, sellAmount, "Allowance must persist for vaultRelayer to pull tokens at settlement time");
    }

    function test_EIP1271_IsValidSignature_ApprovedDigest() public {
        bytes32 digest = keccak256("test order digest");
        cowProvider.approveOrderDigest(digest);

        bytes4 result = cowProvider.isValidSignature(digest, "");
        assertEq(result, MAGICVALUE);
    }

    function test_EIP1271_IsValidSignature_UnapprovedDigest() public view {
        bytes32 digest = keccak256("unapproved digest");

        bytes4 result = cowProvider.isValidSignature(digest, "");
        assertTrue(result != MAGICVALUE);
    }

    function test_EIP1271_RevokeOrderDigest() public {
        bytes32 digest = keccak256("revocable digest");
        cowProvider.approveOrderDigest(digest);
        assertTrue(cowProvider.approvedOrderDigests(address(this), digest));

        cowProvider.revokeOrderDigest(digest);
        assertFalse(cowProvider.approvedOrderDigests(address(this), digest));

        bytes4 result = cowProvider.isValidSignature(digest, "");
        assertTrue(result != MAGICVALUE);
    }

    function test_CancelTrade_RevokesPreSignature() public {
        uint256 sellAmount = 1000 * 1e6;
        uint256 buyAmountMin = 1e15;
        uint32 validTo = uint32(block.timestamp + 3600);

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(cowProvider), sellAmount);

        bytes memory swapData =
            abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), buyAmountMin, validTo);

        cowProvider.trade(swapData);

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(mainnet.USDC)),
            buyToken: IERC20(address(mainnet.WETH)),
            receiver: address(this),
            sellAmount: sellAmount,
            buyAmount: buyAmountMin,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes32 digest = cowProvider.getOrderDigest(order);
        assertTrue(cowProvider.approvedOrderDigests(address(this), digest));
        assertEq(
            IERC20(address(mainnet.USDC)).allowance(address(cowProvider), cowProvider.vaultRelayer()),
            sellAmount,
            "vault relayer allowance set after trade"
        );

        cowProvider.cancelTrade(abi.encode(digest, validTo));

        assertEq(
            IERC20(address(mainnet.USDC)).allowance(address(cowProvider), cowProvider.vaultRelayer()),
            0,
            "vault relayer allowance revoked after cancel"
        );
        assertFalse(cowProvider.approvedOrderDigests(address(this), digest));
        bytes4 result = cowProvider.isValidSignature(digest, "");
        assertTrue(result != MAGICVALUE);
    }

    function test_Swap_WithBuyOrder() public {
        uint256 sellAmount = 1000 * 1e6;
        uint256 buyAmountMin = 1e15;
        uint32 validTo = uint32(block.timestamp + 3600);
        bool isSellOrder = false;

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(cowProvider), sellAmount);

        bytes memory swapData =
            abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), buyAmountMin, validTo, isSellOrder);

        cowProvider.trade(swapData);

        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(cowProvider)), sellAmount);
    }

    function test_CancelTrade_ReturnsSellTokensToVault() public {
        uint256 sellAmount = 1000 * 1e6;
        uint256 buyAmountMin = 1e15;
        uint32 validTo = uint32(block.timestamp + 3600);

        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(cowProvider), sellAmount);

        bytes memory swapData =
            abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), buyAmountMin, validTo);
        cowProvider.trade(swapData);

        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(cowProvider)), sellAmount);
        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(this)), 0);

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(mainnet.USDC)),
            buyToken: IERC20(address(mainnet.WETH)),
            receiver: address(this),
            sellAmount: sellAmount,
            buyAmount: buyAmountMin,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes32 digest = cowProvider.getOrderDigest(order);
        cowProvider.cancelTrade(abi.encode(digest, validTo));

        assertEq(
            IERC20(address(mainnet.USDC)).balanceOf(address(cowProvider)),
            0,
            "provider balance should be 0 after cancel"
        );
        assertEq(
            IERC20(address(mainnet.USDC)).balanceOf(address(this)),
            sellAmount,
            "sell tokens returned to vault after cancel"
        );
    }

    function _placeTrade(uint256 sellAmount, uint32 validTo) internal returns (bytes32 digest) {
        deal(address(mainnet.USDC), address(this), sellAmount);
        IERC20(address(mainnet.USDC)).safeApprove(address(cowProvider), sellAmount);
        bytes memory swapData = abi.encode(address(mainnet.USDC), sellAmount, address(mainnet.WETH), 1e15, validTo);
        cowProvider.trade(swapData);

        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(mainnet.USDC)),
            buyToken: IERC20(address(mainnet.WETH)),
            receiver: address(this),
            sellAmount: sellAmount,
            buyAmount: 1e15,
            validTo: validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        digest = cowProvider.getOrderDigest(order);
    }

    function test_CleanExpiredOrders_RevertsIfNotExpired() public {
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes32 digest = _placeTrade(1000e6, validTo);

        bytes32[] memory digests = new bytes32[](1);
        digests[0] = digest;
        vm.expectRevert(OrderNotExpired.selector);
        cowProvider.cleanExpiredOrders(digests);
    }

    function test_CleanExpiredOrders_PermissionlesslyCleanupAfterExpiry() public {
        uint256 sellAmount = 1000e6;
        uint32 validTo = uint32(block.timestamp + 3600);
        bytes32 digest = _placeTrade(sellAmount, validTo);

        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(cowProvider)), sellAmount);
        assertEq(IERC20(address(mainnet.USDC)).allowance(address(cowProvider), cowProvider.vaultRelayer()), sellAmount);

        vm.warp(validTo + 1);

        bytes32[] memory digests = new bytes32[](1);
        digests[0] = digest;
        vm.prank(address(0xdead));
        cowProvider.cleanExpiredOrders(digests);

        assertEq(
            IERC20(address(mainnet.USDC)).allowance(address(cowProvider), cowProvider.vaultRelayer()),
            0,
            "approval must be 0 after clean"
        );
        assertEq(IERC20(address(mainnet.USDC)).balanceOf(address(cowProvider)), 0, "provider must hold no tokens");
        assertEq(
            IERC20(address(mainnet.USDC)).balanceOf(address(this)), sellAmount, "tokens returned to vault after clean"
        );
        assertFalse(cowProvider.approvedOrderDigests(address(this), digest), "digest must be revoked");
    }

    function test_GetOrderDigest_MatchesManualHash() public view {
        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(mainnet.USDC)),
            buyToken: IERC20(address(mainnet.WETH)),
            receiver: address(this),
            sellAmount: 1000e6,
            buyAmount: 1e15,
            validTo: uint32(block.timestamp + 3600),
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes32 digestFromProvider = cowProvider.getOrderDigest(order);
        bytes32 domainSeparator = IGPv2Settlement(mainnet.COW_SETTLEMENT).domainSeparator();
        bytes32 manualDigest = GPv2Order.hash(order, domainSeparator);

        assertEq(digestFromProvider, manualDigest);
    }
}
