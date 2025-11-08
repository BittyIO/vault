// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {ITrust} from "../src/interfaces/ITrust.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";

interface IWETH {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
}

contract MockWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract BittyVaultGrantorTest is Test {
    BittyVault public bittyVault;
    MockWETH public mockWETH;

    function setUp() public {
        mockWETH = new MockWETH();
        bittyVault = new BittyVault();
        bittyVault.setAsset(IAssetManager.AssetType.WETH, address(mockWETH));
    }

    function test_InitErrorWithGrantorAddressZero() public {
        vm.expectRevert(ITrust.AddressZero.selector);
        bittyVault.initialize(address(0));
    }

    function test_InitErrorWithAlreadyInitialized() public {
        bittyVault.initialize(address(1));
        vm.expectRevert(ITrust.AlreadyInitialized.selector);
        bittyVault.initialize(address(1));
    }

    function test_SetTrustToIrrevocable() public {
        bittyVault.initialize(address(this));
        bittyVault.setToIrrevocable();
        assertEq(bittyVault.revocable(), false);
    }

    function test_RevocableAfterPing() public {
        bittyVault.initialize(address(this));
        bittyVault.setAutoIrrevocableAfterNoPing(2);
        bittyVault.ping();
        vm.warp(block.timestamp + 1);
        assertEq(bittyVault.revocable(), true);
    }

    function test_AutoIrrevocableAfterNoPing() public {
        bittyVault.initialize(address(this));
        bittyVault.setAutoIrrevocableAfterNoPing(1);
        vm.warp(block.timestamp + 2);
        assertEq(bittyVault.revocable(), false);
    }
}
