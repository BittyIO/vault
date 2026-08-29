// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";

interface IFacetCall {
    function updateAssets(address[] calldata add, address[] calldata remove) external;
}

/**
 * The highest-risk piece of the whole design: one shared facet, delegatecalled by two different hosts,
 * must resolve `owner()` to the HOST's owner (via OZ's fixed ERC-7201 slot). If that wiring is wrong,
 * a sub owner could drive the main vault's DeFi, or vice versa. These tests pin it down with no guard,
 * no forwarder — pure storage/auth resolution.
 */
contract SubVaultFacetAuthTest is Test {
    BittyV1VaultDeFiFacet facet;
    BittyV1Vault mainImpl;
    BittyV1SubVault subImpl;

    address mainVault;
    address subVault;

    address mainOwner = makeAddr("mainOwner");
    address subOwner = makeAddr("subOwner");
    address stranger = makeAddr("stranger");
    address weth = makeAddr("weth");

    function setUp() public {
        facet = new BittyV1VaultDeFiFacet();
        subImpl = new BittyV1SubVault(address(facet));
        mainImpl = new BittyV1Vault(address(facet), address(subImpl));

        bytes memory mainInit = abi.encodeCall(BittyV1Vault.initialize, (mainOwner, weth, false, address(0), 0));
        mainVault = address(new ERC1967Proxy(address(mainImpl), mainInit));

        // A sub vault whose parent is the main vault, owned by a different account.
        bytes memory subInit = abi.encodeCall(
            BittyV1SubVault.initialize, (mainVault, subOwner, false, uint64(block.timestamp + 365 days))
        );
        subVault = address(new ERC1967Proxy(address(subImpl), subInit));
    }

    function test_ownersAndParentLinkResolveIndependently() public view {
        assertEq(BittyV1Vault(payable(mainVault)).owner(), mainOwner, "main owner");
        assertEq(BittyV1SubVault(payable(subVault)).owner(), subOwner, "sub owner");
        assertEq(BittyV1SubVault(payable(subVault)).vault(), mainVault, "parent link");
        assertEq(BittyV1SubVault(payable(subVault)).subOwner(), subOwner, "subOwner()");
    }

    function test_mainFacetAuthResolvesToMainOwner() public {
        // The main owner drives the main vault's DeFi (empty update touches no guard, only the auth gate).
        vm.prank(mainOwner);
        IFacetCall(mainVault).updateAssets(new address[](0), new address[](0));

        // A stranger cannot.
        vm.prank(stranger);
        vm.expectRevert();
        IFacetCall(mainVault).updateAssets(new address[](0), new address[](0));
    }

    function test_subFacetAuthResolvesToSubOwner() public {
        // The sub owner drives the sub vault's DeFi.
        vm.prank(subOwner);
        IFacetCall(subVault).updateAssets(new address[](0), new address[](0));

        // A stranger cannot.
        vm.prank(stranger);
        vm.expectRevert();
        IFacetCall(subVault).updateAssets(new address[](0), new address[](0));
    }

    function test_mainOwnerCannotDriveSubFacet_andViceVersa() public {
        // The crux: the shared facet reads the HOST's owner. The main owner is NOT the sub's owner,
        // so it must be rejected on the sub — and the sub owner must be rejected on the main vault.
        vm.prank(mainOwner);
        vm.expectRevert();
        IFacetCall(subVault).updateAssets(new address[](0), new address[](0));

        vm.prank(subOwner);
        vm.expectRevert();
        IFacetCall(mainVault).updateAssets(new address[](0), new address[](0));
    }
}
