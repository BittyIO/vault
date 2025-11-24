// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {ITrust} from "../src/interfaces/ITrust.sol";
import {AddressZero} from "../src/interfaces/Errors.sol";
import {WhiteList} from "../src/WhiteList.sol";

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
    address public whiteListAddress;

    function setUp() public {
        mockWETH = new MockWETH();
        bittyVault = new BittyVault();
        whiteListAddress = address(new WhiteList());
        bittyVault.initialize(
            address(this),
            address(mockWETH),
            whiteListAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_InitErrorWithGrantorAddressZero() public {
        BittyVault newVault = new BittyVault();
        vm.expectRevert(AddressZero.selector);
        newVault.initialize(
            address(0),
            address(mockWETH),
            whiteListAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_InitErrorWithAlreadyInitialized() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(1),
            address(mockWETH),
            whiteListAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        vm.expectRevert();
        newVault.initialize(
            address(1),
            address(mockWETH),
            whiteListAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_SetTrustToIrrevocable() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            address(mockWETH),
            whiteListAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        newVault.setToIrrevocable();
        assertEq(newVault.revocable(), false);
    }

    function test_RevocableAfterPing() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            address(mockWETH),
            whiteListAddress,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        newVault.setAutoIrrevocableAfterNoPing(2);
        newVault.ping();
        vm.warp(block.timestamp + 1);
        assertEq(newVault.revocable(), true);
    }

    function test_AutoIrrevocableAfterNoPing() public {
        BittyVault newVault = new BittyVault();
        newVault.initaialize(address(this), address(1));
        newVault.setAutoIrrevocableAfterNoPing(1);
        vm.warp(block.timestamp + 2);
        assertEq(newVault.revocable(), false);
    }

    function test_ChangeGrantorAddressErrorWithNotRevocable() public {
        BittyVault newVault = new BittyVault();
        newVault.initaialize(address(this), address(1));
        newVault.setToIrrevocable();
        vm.expectRevert("Only revocable");
        newVault.changeGrantorAddress(address(1));
    }

    function test_ChangeGrantorAddressErrorWithAddressZero() public {
        BittyVault newVault = new BittyVault();
        newVault.initaialize(address(this), address(1));
        vm.expectRevert(AddressZero.selector);
        newVault.changeGrantorAddress(address(0));
    }
}
