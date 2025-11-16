// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {Assets} from "../src/Assets.sol";

contract AssetsTest is Test {
    Assets public assets;
    address public protocolOwner;

    function setUp() public {
        protocolOwner = makeAddr("protocolOwner");
        assets = new Assets();
        address txOrigin = tx.origin;
        vm.prank(txOrigin);
        assets.transferOwnership(protocolOwner);
    }

    function test_AddWhiteListedAsset() public {
        vm.prank(protocolOwner);
        assets.add(address(1));
        assertEq(assets.isWhiteListed(address(1)), true);
    }

    function test_RemoveWhiteListedAsset() public {
        vm.prank(protocolOwner);
        assets.add(address(1));
        vm.prank(protocolOwner);
        assets.remove(address(1));
        assertEq(assets.isWhiteListed(address(1)), false);
    }

    function test_IsWhiteListed() public {
        vm.prank(protocolOwner);
        assets.add(address(1));
        assertEq(assets.isWhiteListed(address(1)), true);
        vm.prank(protocolOwner);
        assets.remove(address(1));
        assertEq(assets.isWhiteListed(address(1)), false);
    }
}
