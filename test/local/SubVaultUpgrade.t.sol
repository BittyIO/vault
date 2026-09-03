// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {ImplementationNotRegistered} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

contract MockImplRegistry {
    // Keyed by category: a main vault and a sub vault are separate registries, so blessing a build
    // for one must not bless it for the other.
    mapping(uint8 => mapping(address => bool)) internal _registered;

    function isImplementationRegisteredFor(address impl, uint8 category) external view returns (bool) {
        return _registered[category][impl];
    }

    function setRegistered(address impl, bool ok) external {
        _registered[1][impl] = ok; // main-vault category, which is what this suite upgrades
    }
}

/**
 * The upgrade guardrails, in the guard-timelocked model: owner-only, restricted to a guard-BLESSED
 * implementation (the guard holds the timelock, so per-vault upgrades are immediate), and freezable into
 * immutability. The curation + freeze are what keep a compromised key from adopting backdoored code.
 */
contract SubVaultUpgradeTest is Test {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    BittyV1VaultDeFiFacet facet;
    BittyV1Vault implV1;
    BittyV1Vault implV2;
    address vault;

    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");
    address weth = makeAddr("weth");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockImplRegistry()).code);

        facet = new BittyV1VaultDeFiFacet();
        implV1 = new BittyV1Vault(address(facet), address(0));
        implV2 = new BittyV1Vault(address(facet), address(0));
        MockImplRegistry(BITTY_GUARD).setRegistered(address(implV2), true);

        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
        vault = address(new ERC1967Proxy(address(implV1), init));
    }

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(vault, IMPL_SLOT))));
    }

    function test_upgradeToBlessedImplIsImmediate() public {
        assertEq(_impl(), address(implV1), "starts on v1");

        vm.prank(owner);
        BittyV1Vault(payable(vault)).upgrade(address(implV2));

        assertEq(_impl(), address(implV2), "upgraded immediately, same address");
        assertEq(BittyV1Vault(payable(vault)).owner(), owner, "state preserved across upgrade");
    }

    function test_unregisteredImplRejected() public {
        BittyV1Vault rogue = new BittyV1Vault(address(facet), address(0)); // not blessed by the guard
        vm.prank(owner);
        vm.expectRevert(ImplementationNotRegistered.selector);
        BittyV1Vault(payable(vault)).upgrade(address(rogue));
    }

    function test_nonOwnerCannotUpgrade() public {
        vm.prank(stranger);
        vm.expectRevert();
        BittyV1Vault(payable(vault)).upgrade(address(implV2));
    }
}
