// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {IBittyV1SubVault, NotParentVault, NotSubOwner} from "../../src/interfaces/IBittyV1SubVault.sol";

/**
 * The payout-monopoly invariant, enforced structurally: a sub vault's only asset exits are `recall`
 * (parent-only) and `returnToVault` (sub-owner, to the parent). There is no function that sends to an
 * arbitrary address, so a fully compromised sub owner can never exfiltrate — the worst they can do is
 * hand funds back to the parent.
 */
contract SubVaultIsolationTest is Test {
    BittyV1VaultDeFiFacet facet;
    BittyV1SubVault subImpl;
    address subVault;

    address parent = makeAddr("parent");
    address subOwner = makeAddr("subOwner");
    address attacker = makeAddr("attacker");
    MockERC20 usdc;

    function setUp() public {
        facet = new BittyV1VaultDeFiFacet();
        subImpl = new BittyV1SubVault(address(facet));
        subVault = address(
            new ERC1967Proxy(
                address(subImpl),
                abi.encodeCall(
                    BittyV1SubVault.initialize, (parent, subOwner, false, uint64(block.timestamp + 365 days))
                )
            )
        );
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(subVault, 1_000e6);
    }

    function test_returnToVault_reachesParentNeverSubOwner() public {
        vm.prank(subOwner);
        IBittyV1SubVault(subVault).returnToVault(_one(address(usdc)), _one(400e6));
        assertEq(usdc.balanceOf(parent), 400e6, "funds went to the parent");
        assertEq(usdc.balanceOf(subOwner), 0, "never to the sub owner");
        assertEq(usdc.balanceOf(subVault), 600e6, "remainder stays in the sub");
    }

    function test_subOwnerCannotForceRecall() public {
        // recall is parent-only; even the sub owner can't invoke it.
        vm.prank(subOwner);
        vm.expectRevert(NotParentVault.selector);
        IBittyV1SubVault(subVault).recall(_one(address(usdc)), _one(100e6));
    }

    function test_onlyParentCanRecall() public {
        vm.prank(parent);
        IBittyV1SubVault(subVault).recall(_one(address(usdc)), _one(300e6));
        assertEq(usdc.balanceOf(parent), 300e6, "parent pulled funds back");
    }

    function test_attackerCannotExit() public {
        vm.prank(attacker);
        vm.expectRevert(NotSubOwner.selector);
        IBittyV1SubVault(subVault).returnToVault(_one(address(usdc)), _one(100e6));

        vm.prank(attacker);
        vm.expectRevert(NotParentVault.selector);
        IBittyV1SubVault(subVault).recall(_one(address(usdc)), _one(100e6));

        assertEq(usdc.balanceOf(attacker), 0, "attacker got nothing");
    }

    function test_noArbitraryTransferPathExists() public {
        // A made-up transfer selector falls through to the facet, which has no such function either →
        // it reverts. There is simply no code path that sends the sub's assets to an arbitrary address.
        vm.prank(subOwner);
        (bool ok,) = subVault.call(abi.encodeWithSignature("transfer(address,uint256)", attacker, 100e6));
        assertFalse(ok, "no arbitrary-transfer function exists on the sub or its facet");
        assertEq(usdc.balanceOf(attacker), 0, "nothing left the sub");
        assertEq(usdc.balanceOf(subVault), 1_000e6, "sub balance intact");
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _one(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }
}
