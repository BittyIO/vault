// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {AddressZero, AlreadyInitialized} from "../src/interfaces/Errors.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {WhiteList} from "../src/WhiteList.sol";

contract BittyVaultTest is Test {
    BittyVault public bittyVault;
    WETH public weth;
    address public whiteListAddress;
    address public grantorAddress;

    function setUp() public {
        weth = new WETH();
        bittyVault = new BittyVault();
        whiteListAddress = address(new WhiteList());
        grantorAddress = makeAddr("grantorAddress");
    }

    function test_InitErrorWithWethAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        bittyVault.initialize(
            address(grantorAddress),
            address(whiteListAddress),
            address(0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_InitErrorWithAlreadyInitialized() public {
        bittyVault.initialize(
            address(grantorAddress),
            address(whiteListAddress),
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        vm.expectRevert(AlreadyInitialized.selector);
        bittyVault.initialize(
            address(grantorAddress),
            address(whiteListAddress),
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }
}
