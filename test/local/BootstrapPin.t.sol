// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {BittyV1VaultBootstrap} from "../../src/BittyV1VaultBootstrap.sol";
import {BittyV1VaultFactoryBootstrap} from "../../src/BittyV1VaultFactoryBootstrap.sol";
import {BittyV1ForwarderBootstrap} from "../../src/BittyV1ForwarderBootstrap.sol";
import {BITTY_VAULT_BOOTSTRAP, BITTY_VAULT_FACTORY_BOOTSTRAP} from "../../src/logic/Constants.sol";
import {
    VAULT_BOOTSTRAP_INITCODE,
    VAULT_FACTORY_BOOTSTRAP_INITCODE,
    FORWARDER_BOOTSTRAP_INITCODE,
    FORWARDER_BOOTSTRAP
} from "../../script/BootstrapInitCode.sol";

/**
 * @dev The bootstraps are deployed from pinned bytes, not compiled, so their metadata hash - and with
 *      it every address born on them - cannot move. These tests hold each pin to two things: that it
 *      still lands where the constants say, and that its code is still what the source compiles to.
 */
contract BootstrapPinTest is Test {
    address constant SIMPLE_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function test_pinnedBootstrapsLandAtTheirConstants() public pure {
        assertEq(_create2(VAULT_BOOTSTRAP_INITCODE), BITTY_VAULT_BOOTSTRAP, "vault bootstrap");
        assertEq(_create2(VAULT_FACTORY_BOOTSTRAP_INITCODE), BITTY_VAULT_FACTORY_BOOTSTRAP, "factory bootstrap");
        assertEq(_create2(FORWARDER_BOOTSTRAP_INITCODE), FORWARDER_BOOTSTRAP, "forwarder bootstrap");
        // The forwarder PROXY on top of it is not checked here: ERC1967Proxy's metadata differs between
        // this profile and `deploy`, so only Deploy.s.sol, built under `deploy`, can hold it to
        // BITTY_FORWARDER - which it does.
    }

    /**
     * @dev Only the trailing CBOR metadata may differ: an edit that changes what a bootstrap DOES
     *      fails here, and needs a deliberate new pin and new addresses.
     */
    function test_pinnedBootstrapsMatchTheSourceButForMetadata() public pure {
        assertEq(_stripMetadata(VAULT_BOOTSTRAP_INITCODE), _stripMetadata(type(BittyV1VaultBootstrap).creationCode));
        assertEq(
            _stripMetadata(VAULT_FACTORY_BOOTSTRAP_INITCODE),
            _stripMetadata(type(BittyV1VaultFactoryBootstrap).creationCode)
        );
        assertEq(
            _stripMetadata(FORWARDER_BOOTSTRAP_INITCODE), _stripMetadata(type(BittyV1ForwarderBootstrap).creationCode)
        );
    }

    function _create2(bytes memory initCode) private pure returns (address) {
        return vm.computeCreate2Address(bytes32(0), keccak256(initCode), SIMPLE_CREATE2);
    }

    /**
     * @dev Drops solc's trailing CBOR blob, whose length is the code's last two bytes.
     */
    function _stripMetadata(bytes memory code) private pure returns (bytes memory out) {
        uint256 n = code.length;
        uint256 cbor = (uint256(uint8(code[n - 2])) << 8) | uint8(code[n - 1]);
        out = new bytes(n - cbor - 2);
        for (uint256 i; i < out.length; ++i) {
            out[i] = code[i];
        }
    }
}
