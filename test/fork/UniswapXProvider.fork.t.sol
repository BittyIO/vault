// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {UniswapXProvider} from "../../src/providers/UniswapXProvider.sol";
import {mainnet} from "../../script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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
