// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {BITTY_GUARD, BITTY_FORWARDER} from "../../src/logic/Constants.sol";

/// The facet's views, reached through the host's fallback — `allowlistEnabled` lives on the shared
/// DeFi facet, not on the vault, so a plain BittyV1Vault handle cannot see it.
interface IFacetViews {
    function allowlistEnabled() external view returns (bool);
}

/**
 * Batching must GRANT NOTHING.
 *
 * {MulticallUpgradeable} self-delegatecalls each entry, so `msg.sender` and storage stay the caller's
 * and every call is authorised exactly as it would be sent on its own. These pin that, on both
 * account kinds, including through the forwarder — where a hand-rolled loop would drop the ERC-2771
 * sender suffix and silently attribute the batch to the forwarder instead of the signer.
 */
contract MulticallTest is Test {
    BittyV1VaultDeFiFacet facet;
    BittyV1Vault vaultImpl;
    BittyV1SubVault subImpl;
    BittyV1Vault vault;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address subOwner = makeAddr("subOwner");
    address stranger = makeAddr("stranger");
    address weth = makeAddr("weth");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        facet = new BittyV1VaultDeFiFacet();
        subImpl = new BittyV1SubVault(address(facet));
        vaultImpl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(vaultImpl), init)));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(address(vault), 1_000e6);
    }

    function _newSub() internal returns (uint256 id, BittyV1SubVault sub) {
        vm.prank(owner);
        (uint256 subId, address account) = vault.createSubVault(subOwner, false, uint64(block.timestamp) + 365 days);
        return (subId, BittyV1SubVault(payable(account)));
    }

    /// A relayed call: the forwarder appends the signer's address, which is what _msgSender reads.
    function _relay(address account, bytes memory data, address signer) internal {
        vm.prank(BITTY_FORWARDER);
        (bool ok,) = account.call(abi.encodePacked(data, signer));
        require(ok, "relayed call failed");
    }

    // ── main vault ────────────────────────────────────────────────────────────

    /// The ordinary path: owner pays gas from their own wallet, no forwarder involved.
    function test_ownerBatchesFromTheirOwnWallet() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(BittyV1Vault.enableAllowlist, ());
        calls[1] = abi.encodeCall(BittyV1Vault.createSubVault, (subOwner, false, uint64(block.timestamp + 365 days)));

        vm.prank(owner);
        vault.multicall(calls);

        assertTrue(IFacetViews(address(vault)).allowlistEnabled(), "first entry applied");
        assertEq(vault.subVaultOpenCount(), 1, "second entry applied in the same transaction");
    }

    /// Batching cannot be used to act as someone else: a stranger's batch is refused per call.
    function test_batchDoesNotEscalate() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(BittyV1Vault.enableAllowlist, ());

        vm.prank(stranger);
        vm.expectRevert();
        vault.multicall(calls);

        assertFalse(IFacetViews(address(vault)).allowlistEnabled(), "unchanged");
    }

    /// A failing entry reverts the whole batch — no partial application.
    function test_batchIsAllOrNothing() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(BittyV1Vault.enableAllowlist, ());
        // Not the owner's to call twice: the second enable reverts, taking the first with it.
        calls[1] = abi.encodeCall(BittyV1Vault.createSubVault, (address(0), false, uint64(block.timestamp + 365 days)));

        vm.prank(owner);
        vm.expectRevert();
        vault.multicall(calls);

        assertFalse(IFacetViews(address(vault)).allowlistEnabled(), "the first call was rolled back too");
        assertEq(vault.subVaultOpenCount(), 0, "nothing created");
    }

    // ── sub vault ─────────────────────────────────────────────────────────────

    /// A sub vault batches on the same terms, authorised against ITS owner.
    function test_subOwnerBatchesOnTheirOwnSubVault() public {
        (, BittyV1SubVault sub) = _newSub();

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(BittyV1SubVault.setGasless, (10, 1));

        vm.prank(subOwner);
        sub.multicall(calls);

        (, uint256 daily, uint256 perOp) = sub.gaslessConfig();
        assertEq(daily, 10, "sub owner's batch applied");
        assertEq(perOp, 1);
    }

    /**
     * The isolation that matters once accounts nest: the MAIN owner is not the sub's owner, and
     * batching must not become a way around that. Ownership is per-account, and so is the batch.
     */
    function test_mainOwnerCannotBatchIntoASubVault() public {
        (, BittyV1SubVault sub) = _newSub();

        (, uint256 dailyBefore,) = sub.gaslessConfig();

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(BittyV1SubVault.setGasless, (10, 1));

        vm.prank(owner);
        vm.expectRevert();
        sub.multicall(calls);

        // Compared against the pre-state rather than 0: an unset limit reads back as the system
        // default, so asserting 0 would be asserting the wrong thing whether or not the batch landed.
        (, uint256 dailyAfter,) = sub.gaslessConfig();
        assertEq(dailyAfter, dailyBefore, "the main owner's batch changed nothing");
    }

    function test_strangerCannotBatchIntoASubVault() public {
        (, BittyV1SubVault sub) = _newSub();

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(BittyV1SubVault.setGasless, (10, 1));

        vm.prank(stranger);
        vm.expectRevert();
        sub.multicall(calls);
    }

    // ── relayed ───────────────────────────────────────────────────────────────

    /**
     * The reason to use OpenZeppelin's implementation rather than a loop.
     *
     * Each entry is re-dispatched with the ERC-2771 suffix re-appended, so `_msgSender()` inside every
     * sub-call is still the SIGNER. A naive `for` loop delegatecalling `data[i]` alone drops the
     * suffix, and each sub-call would then resolve its sender to the forwarder — every owner-gated
     * entry in a relayed batch would revert, or worse, pass for the wrong account.
     */
    function test_relayedBatchIsAttributedToTheSignerNotTheForwarder() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(BittyV1Vault.enableAllowlist, ());
        calls[1] = abi.encodeCall(BittyV1Vault.createSubVault, (subOwner, false, uint64(block.timestamp + 365 days)));

        _relay(address(vault), abi.encodeCall(vault.multicall, (calls)), owner);

        assertTrue(IFacetViews(address(vault)).allowlistEnabled(), "relayed batch applied as the owner");
        assertEq(vault.subVaultOpenCount(), 1, "both entries, one transaction, no ETH from the owner");
    }

    /// The same suffix handling must not let the FORWARDER act on its own behalf.
    function test_relayedBatchFromANonOwnerSignerIsRefused() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(BittyV1Vault.enableAllowlist, ());

        vm.prank(BITTY_FORWARDER);
        (bool ok,) = address(vault).call(abi.encodePacked(abi.encodeCall(vault.multicall, (calls)), stranger));
        assertFalse(ok, "a relayed batch signed by a stranger is refused");
        assertFalse(IFacetViews(address(vault)).allowlistEnabled(), "unchanged");
    }
}
