// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * Native ETH sent to a sub is wrapped to WETH on receipt (like the main vault), so it is never
 * stranded — it becomes an ERC-20 the parent can recall.
 */
contract SubVaultNativeWrapTest is Test {
    BittyV1Vault vault;
    WETH gasWrapped;
    address owner = makeAddr("owner");
    address subOwner = makeAddr("subOwner");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        gasWrapped = new WETH();
        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        BittyV1Vault.initialize, (owner, address(gasWrapped), false, address(0), 0, new bytes[](0))
                    )
                ))
        );
    }

    function test_ethSentToASubIsWrappedAndRecallable() public {
        vm.prank(owner);
        (uint256 subId, address sub) = vault.createSubVault(subOwner, false, uint64(block.timestamp) + 365 days);

        // Raw ETH into the sub → receive() wraps it to WETH.
        vm.deal(address(this), 1 ether);
        (bool ok,) = sub.call{value: 1 ether}("");
        assertTrue(ok, "sub accepted ETH");
        assertEq(sub.balance, 0, "no raw ETH left in the sub");
        assertEq(gasWrapped.balanceOf(sub), 1 ether, "ETH wrapped to WETH in the sub");

        // The parent can recall the WETH — no stranding.
        address[] memory a = new address[](1);
        uint256[] memory m = new uint256[](1);
        a[0] = address(gasWrapped);
        m[0] = 1 ether;
        vm.prank(owner);
        vault.recallFromSubVault(subId, a, m);
        assertEq(gasWrapped.balanceOf(sub), 0, "recalled out of the sub");
        assertEq(gasWrapped.balanceOf(address(vault)), 1 ether, "landed in the parent");
    }

    function test_ethFromWethIsNotRewrapped() public {
        vm.prank(owner);
        (, address sub) = vault.createSubVault(subOwner, false, uint64(block.timestamp) + 365 days);

        // WETH refunding ETH (as on withdraw) must fall through untouched — never re-wrapped.
        vm.deal(address(gasWrapped), 1 ether);
        vm.prank(address(gasWrapped));
        (bool ok,) = sub.call{value: 1 ether}("");
        assertTrue(ok, "sub accepted the refund");
        assertEq(sub.balance, 1 ether, "raw ETH stays; no re-wrap");
        assertEq(gasWrapped.balanceOf(sub), 0, "no WETH minted from a WETH-sourced transfer");
    }
}
