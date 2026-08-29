// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {BittyV1AutoYieldKeeper} from "../../src/BittyV1AutoYieldKeeper.sol";

/**
 * The keeper is an IDENTITY, not an actor: vaults name one immutable address as their auto-yield
 * trigger, and the hot keys that actually sign rotate inside it. Rotation is one transaction here
 * instead of one per vault — which is the only reason this contract exists.
 */
contract KeeperTest is Test {
    BittyV1AutoYieldKeeper keeper;

    address kOwner = makeAddr("keeperOwner");
    address forwarder = makeAddr("forwarder");
    uint256 signerPk = 0xBEEF;
    address signer;

    bytes4 constant MAGIC = 0x1626ba7e;
    bytes4 constant INVALID = 0xffffffff;

    function setUp() public {
        signer = vm.addr(signerPk);
        keeper = new BittyV1AutoYieldKeeper(kOwner);
        vm.startPrank(kOwner);
        keeper.setForwarder(forwarder, true);
        keeper.setSigner(signer, uint64(block.timestamp + 30 days));
        vm.stopPrank();
    }

    /// The payload is abi.encode(signer, innerSignature) — the keeper is told who to check.
    function _payload(uint256 pk, bytes32 hash, address named) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = _sign(pk, hash);
        return abi.encode(named, abi.encodePacked(r, s, v));
    }

    function _sign(uint256 pk, bytes32 hash) internal pure returns (uint8, bytes32, bytes32) {
        return vm.sign(pk, hash);
    }

    function _ask(bytes32 hash, bytes memory sig) internal returns (bytes4) {
        vm.prank(forwarder);
        return keeper.isValidSignature(hash, sig);
    }

    function test_acceptsAnActiveSignerAskedByATrustedForwarder() public {
        bytes32 h = keccak256("sweep");
        assertEq(_ask(h, _payload(signerPk, h, signer)), MAGIC);
    }

    /**
     * The msg.sender gate. Without it this is a general-purpose ERC-1271 identity that Permit2,
     * Seaport or anything else accepting contract signatures would honour — far more authority than
     * sweeping vaults into routes their owners already chose.
     */
    function test_rejectsAnyoneOtherThanATrustedForwarder() public {
        bytes32 h = keccak256("sweep");
        bytes memory sig = _payload(signerPk, h, signer);
        vm.prank(makeAddr("someOtherProtocol"));
        assertEq(keeper.isValidSignature(h, sig), INVALID);
    }

    function test_rejectsAStrangerKey() public {
        (address stranger, uint256 strangerPk) = makeAddrAndKey("stranger");
        bytes32 h = keccak256("sweep");
        assertEq(_ask(h, _payload(strangerPk, h, stranger)), INVALID);
    }

    /// Naming a registered signer does not help if the signature is not theirs.
    function test_cannotBorrowARegisteredSignersName() public {
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        bytes32 h = keccak256("sweep");
        assertEq(_ask(h, _payload(strangerPk, h, signer)), INVALID);
    }

    /// A leak nobody notices stops mattering on its own.
    function test_keyStopsWorkingWhenItExpires() public {
        bytes32 h = keccak256("sweep");
        uint64 expiry = uint64(block.timestamp + 30 days);

        vm.warp(expiry);
        assertEq(_ask(h, _payload(signerPk, h, signer)), MAGIC, "valid on the deadline second");
        vm.warp(expiry + 1);
        assertEq(_ask(h, _payload(signerPk, h, signer)), INVALID, "lapsed with nobody acting");
    }

    function test_ownerCanRevokeImmediately() public {
        vm.prank(kOwner);
        keeper.setSigner(signer, 0);
        bytes32 h = keccak256("sweep");
        assertEq(_ask(h, _payload(signerPk, h, signer)), INVALID);
        assertFalse(keeper.isActiveSigner(signer));
    }

    /// The whole point: one transaction reaches every vault, because every vault names this address.
    function test_rotationIsOneTransactionNotOnePerVault() public {
        (address next, uint256 nextPk) = makeAddrAndKey("hotKey2");
        vm.startPrank(kOwner);
        keeper.setSigner(next, uint64(block.timestamp + 30 days));
        keeper.setSigner(signer, 0);
        vm.stopPrank();

        bytes32 h = keccak256("sweep");
        assertEq(_ask(h, _payload(nextPk, h, next)), MAGIC, "new key works");
        assertEq(_ask(h, _payload(signerPk, h, signer)), INVALID, "old key does not");
    }

    /// A forwarder upgrade leaves two generations of vaults live, so one keeper must serve both.
    function test_servesTwoForwarderGenerationsAtOnce() public {
        address forwarderV2 = makeAddr("forwarderV2");
        vm.prank(kOwner);
        keeper.setForwarder(forwarderV2, true);

        bytes32 h = keccak256("sweep");
        bytes memory sig = _payload(signerPk, h, signer);
        assertEq(_ask(h, sig), MAGIC, "old forwarder still served");
        vm.prank(forwarderV2);
        assertEq(keeper.isValidSignature(h, sig), MAGIC, "new one too");
    }

    /// Malformed input answers explicitly rather than reverting into the caller's staticcall.
    function test_malformedPayloadsAnswerInvalid() public {
        bytes32 h = keccak256("sweep");
        assertEq(_ask(h, hex"dead"), INVALID, "too short for a signer at all");
        assertEq(_ask(h, abi.encode(signer, hex"")), INVALID, "named signer, empty signature");
        assertEq(_ask(h, abi.encode(address(0), hex"00")), INVALID, "zero signer");
    }

    function test_expiryInThePastIsRejected() public {
        vm.warp(1000);
        vm.prank(kOwner);
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

    function test_ownerCannotBeZero() public {
        vm.prank(kOwner);
        vm.expectRevert(BittyV1AutoYieldKeeper.AddressZero.selector);
        keeper.transferOwnership(address(0));
    }

    function test_theKeeperCannotBeDeployedOwnerless() public {
        vm.expectRevert(BittyV1AutoYieldKeeper.AddressZero.selector);
        new BittyV1AutoYieldKeeper(address(0));
    }

    /**
     * The payload is `abi.encode(address,bytes)`, and both of its length fields are attacker-controlled.
     * Each is bounds-checked before the slice that would read past the end, so a hand-built payload
     * answers "not a signer" instead of reverting out of the caller's staticcall.
     */
    function test_anOutOfRangeInnerOffsetAnswersInvalid() public {
        bytes memory sig =
            abi.encodePacked(bytes32(uint256(uint160(signer))), bytes32(uint256(1 << 200)), bytes32(uint256(65)));
        assertEq(_ask(keccak256("sweep"), sig), INVALID, "an offset past the end is refused");
    }

    function test_anOversizedInnerLengthAnswersInvalid() public {
        bytes memory sig =
            abi.encodePacked(bytes32(uint256(uint160(signer))), bytes32(uint256(64)), bytes32(uint256(1 << 200)));
        assertEq(_ask(keccak256("sweep"), sig), INVALID, "a length past the end is refused");
    }

    function test_anOffsetPointingExactlyAtTheEndAnswersInvalid() public {
        bytes memory sig =
            abi.encodePacked(bytes32(uint256(uint160(signer))), bytes32(uint256(96)), bytes32(uint256(1)));
        assertEq(_ask(keccak256("sweep"), sig), INVALID, "no room left for the declared body");
    }

    function test_decodeSignatureReportsNoSignerRatherThanReverting() public view {
        bytes memory sig =
            abi.encodePacked(bytes32(uint256(uint160(signer))), bytes32(uint256(1 << 200)), bytes32(uint256(65)));
        (address got, bytes memory inner) = keeper.decodeSignature(sig);
        assertEq(got, address(0), "no signer");
        assertEq(inner.length, 0, "and no body");
    }

    /// Rotating the keeper's own owner: the signer registry and forwarder trust survive, because they
    /// are the keeper's state, not the owner's — a rotation must not strand every vault pointing here.
    function test_ownershipRotatesAndCarriesTheSignerRegistryWithIt() public {
        address newOwner = makeAddr("newKeeperOwner");
        bytes32 h = keccak256("sweep");
        assertEq(_ask(h, _payload(signerPk, h, signer)), MAGIC, "signing works before the rotation");

        vm.prank(kOwner);
        keeper.transferOwnership(newOwner);
        assertEq(keeper.owner(), newOwner, "rotated");

        assertEq(_ask(h, _payload(signerPk, h, signer)), MAGIC, "and the registry came with it");

        vm.prank(kOwner);
        vm.expectRevert(BittyV1AutoYieldKeeper.NotOwner.selector);
        keeper.setSigner(signer, uint64(block.timestamp + 1 days));

        vm.prank(newOwner);
        keeper.setSigner(signer, 0);
        assertEq(_ask(h, _payload(signerPk, h, signer)), INVALID, "the new owner holds the authority now");
    }
}
