// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {BittyV1AutoYieldKeeper} from "../../src/BittyV1AutoYieldKeeper.sol";
import {BITTY_FORWARDER} from "../../src/logic/Constants.sol";

contract AutoYieldKeeperTest is Test {
    BittyV1AutoYieldKeeper internal keeper;

    address internal owner = makeAddr("keeperOwner");
    address internal forwarder = BITTY_FORWARDER;
    address internal signer;
    uint256 internal signerPk;

    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    function setUp() public {
        (signer, signerPk) = makeAddrAndKey("hotKey");
        keeper = new BittyV1AutoYieldKeeper(owner);
        vm.startPrank(owner);
        keeper.setForwarder(forwarder, true);
        keeper.setSigner(signer, uint64(block.timestamp + 30 days));
        vm.stopPrank();
    }

    function _sig(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        return abi.encodePacked(r, s, v);
    }

    function _ask(bytes32 hash, bytes memory sig) internal returns (bytes4) {
        vm.prank(forwarder);
        return keeper.isValidSignature(hash, sig);
    }

    function test_acceptsAnActiveSignerAskedByATrustedForwarder() public {
        bytes32 h = keccak256("sweep");
        assertEq(_ask(h, _sig(signerPk, h)), MAGIC);
    }

    /// The whole point of the msg.sender gate: this key set is not a general-purpose identity.
    function test_rejectsAnyoneOtherThanATrustedForwarder() public {
        bytes32 h = keccak256("sweep");
        bytes memory sig = _sig(signerPk, h);
        vm.prank(makeAddr("someOtherContract"));
        assertEq(keeper.isValidSignature(h, sig), INVALID);
    }

    function test_rejectsAStrangerKey() public {
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        bytes32 h = keccak256("sweep");
        assertEq(_ask(h, _sig(strangerPk, h)), INVALID);
    }

    /// A leak nobody notices stops mattering on its own.
    function test_keyStopsWorkingWhenItExpires() public {
        bytes32 h = keccak256("sweep");
        uint64 expiry = uint64(block.timestamp + 30 days);

        vm.warp(expiry);
        assertEq(_ask(h, _sig(signerPk, h)), MAGIC, "still valid on the deadline second");

        vm.warp(expiry + 1);
        assertEq(_ask(h, _sig(signerPk, h)), INVALID, "lapsed without anyone acting");
    }

    function test_ownerCanRevokeImmediately() public {
        vm.prank(owner);
        keeper.setSigner(signer, 0);
        bytes32 h = keccak256("sweep");
        assertEq(_ask(h, _sig(signerPk, h)), INVALID);
        assertFalse(keeper.isActiveSigner(signer));
    }

    function test_rotationIsOneTransactionNotOnePerVault() public {
        (address next, uint256 nextPk) = makeAddrAndKey("hotKey2");
        vm.startPrank(owner);
        keeper.setSigner(next, uint64(block.timestamp + 30 days));
        keeper.setSigner(signer, 0);
        vm.stopPrank();

        bytes32 h = keccak256("sweep");
        assertEq(_ask(h, _sig(nextPk, h)), MAGIC, "new key works");
        assertEq(_ask(h, _sig(signerPk, h)), INVALID, "old key does not");
    }

    /// A forwarder upgrade leaves two generations of vaults live, so the keeper must serve both.
    function test_servesTwoForwarderGenerationsAtOnce() public {
        address forwarderV2 = makeAddr("forwarderV2");
        vm.prank(owner);
        keeper.setForwarder(forwarderV2, true);

        bytes32 h = keccak256("sweep");
        bytes memory sig = _sig(signerPk, h);
        assertEq(_ask(h, sig), MAGIC, "old forwarder still served");
        vm.prank(forwarderV2);
        assertEq(keeper.isValidSignature(h, sig), MAGIC, "new forwarder served too");
    }

    function test_expiryInThePastIsRejected() public {
        vm.warp(1000);
        vm.prank(owner);
        vm.expectRevert(BittyV1AutoYieldKeeper.ExpiryInPast.selector);
        keeper.setSigner(signer, uint64(block.timestamp));
    }

    function test_onlyOwnerCanRotateOrRetrust() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(BittyV1AutoYieldKeeper.NotOwner.selector);
        keeper.setSigner(stranger, uint64(block.timestamp + 1 days));
        vm.expectRevert(BittyV1AutoYieldKeeper.NotOwner.selector);
        keeper.setForwarder(stranger, true);
        vm.expectRevert(BittyV1AutoYieldKeeper.NotOwner.selector);
        keeper.transferOwnership(stranger);
        vm.stopPrank();
    }

    function test_malformedSignatureIsRejectedNotReverted() public {
        bytes32 h = keccak256("sweep");
        assertEq(_ask(h, hex"dead"), INVALID);
    }
}
