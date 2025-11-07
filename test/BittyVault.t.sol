// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {Trust} from "../src/Trust.sol";
import {AssetManager} from "../src/AssetManager.sol";
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

contract BittyVaultTest is Test {
    BittyVault public bittyVault;
    MockWETH public mockWETH;

    function setUp() public {
        mockWETH = new MockWETH();
        bittyVault = new BittyVault();
        bittyVault.setAsset(IAssetManager.AssetType.WETH, address(mockWETH));
    }

    function test_InitErrorWithGrantorAddressZero() public {
        vm.expectRevert(Trust.AddressZero.selector);
        bittyVault.initialize(address(0));
    }

    function test_InitErrorWithAlreadyInitialized() public {
        bittyVault.initialize(address(1));
        vm.expectRevert(Trust.AlreadyInitialized.selector);
        bittyVault.initialize(address(1));
    }

    function test_SetTrustToIrrevocable() public {
        bittyVault.initialize(address(this));
        bittyVault.setToIrrevocable();
        assertEq(bittyVault.revocable(), false);
    }

    function test_AutoIrrevocableAfterNoPing() public {
        bittyVault.initialize(address(this));
        bittyVault.setAutoIrrevocableAfterNoPing(1);
        vm.warp(block.timestamp + 2);
        assertEq(bittyVault.revocable(), false);
    }

    function test_RevocableAfterPing() public {
        bittyVault.initialize(address(this));
        bittyVault.setAutoIrrevocableAfterNoPing(2);
        bittyVault.ping();
        vm.warp(block.timestamp + 1);
        assertEq(bittyVault.revocable(), true);
    }

    function test_SetWETHCanOnlyBeCalledOnce() public {
        BittyVault newTrust = new BittyVault();
        address weth1 = address(0x1);
        address weth2 = address(0x2);

        assertEq(address(newTrust.assets(IAssetManager.AssetType.WETH)), address(0));
        newTrust.setAsset(IAssetManager.AssetType.WETH, weth1);
        assertEq(address(newTrust.assets(IAssetManager.AssetType.WETH)), weth1);
        assertTrue(address(newTrust.assets(IAssetManager.AssetType.WETH)) != address(0));

        vm.expectRevert(AssetManager.AssetAlreadySet.selector);
        newTrust.setAsset(IAssetManager.AssetType.WETH, weth2);
    }

    function test_SetWETHRevertsOnZeroAddress() public {
        BittyVault newTrust = new BittyVault();
        vm.expectRevert(Trust.AddressZero.selector);
        newTrust.setAsset(IAssetManager.AssetType.WETH, address(0));
    }
}
