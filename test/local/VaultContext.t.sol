// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BITTY_FORWARDER} from "../../src/logic/Constants.sol";

/**
 * @dev Exposes the vault's resolved `_msgData`, which no vault function reads itself.
 */
contract MsgDataVault is BittyV1Vault {
    constructor(address facet) BittyV1Vault(facet) {}

    function msgDataSeen() external view returns (bytes memory) {
        return _msgData();
    }
}

/**
 * The vault's ERC-2771 context: calldata from the Bitty forwarder carries the signer as a 20-byte
 * suffix, which `_msgData` must strip, and calldata from anyone else is taken as it is.
 */
contract VaultContextTest is Test {
    MsgDataVault vault;
    bytes4 constant SELECTOR = MsgDataVault.msgDataSeen.selector;

    function setUp() public {
        vault = new MsgDataVault(address(new BittyV1VaultDeFiFacet()));
    }

    function test_aDirectCallSeesItsOwnCalldata() public view {
        assertEq(vault.msgDataSeen(), abi.encodePacked(SELECTOR));
    }

    function test_aRelayedCallSeesItWithoutTheSignerSuffix() public {
        vm.prank(BITTY_FORWARDER);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodePacked(SELECTOR, makeAddr("signer")));
        assertTrue(ok);
        assertEq(abi.decode(ret, (bytes)), abi.encodePacked(SELECTOR));
    }

    function test_aSuffixFromAnyoneElseIsKept() public {
        bytes memory data = abi.encodePacked(SELECTOR, makeAddr("signer"));
        vm.prank(makeAddr("stranger"));
        (bool ok, bytes memory ret) = address(vault).call(data);
        assertTrue(ok);
        assertEq(abi.decode(ret, (bytes)), data);
    }
}
