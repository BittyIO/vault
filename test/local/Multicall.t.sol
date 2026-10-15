// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BITTY_GUARD, BITTY_FORWARDER, PERM_YIELD, PERM_SUPPLY, PERM_INTENT} from "../../src/logic/Constants.sol";

/// The facet's views, reached through the host's fallback — `usingBittyAllowList` lives on the shared
/// DeFi facet, not on the vault, so a plain BittyV1Vault handle cannot see it.
interface IFacetViews {
    function usingBittyAllowList() external view returns (bool);
    function autoYieldTrigger() external view returns (address);
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
    BittyV1Vault vault;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address stranger = makeAddr("stranger");
    address gasWrapped = makeAddr("gasWrapped");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        facet = new BittyV1VaultDeFiFacet();
        vaultImpl = new BittyV1Vault(address(facet));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(vaultImpl), init)));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(address(vault), 1_000e6);
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
        calls[0] = abi.encodeCall(BittyV1VaultDeFiFacet.useBittyAllowList, (false));
        calls[1] = abi.encodeCall(BittyV1VaultDeFiFacet.setAutoYieldTrigger, (keeper));

        vm.prank(owner);
        vault.multicall(calls);

        assertFalse(IFacetViews(address(vault)).usingBittyAllowList(), "first entry applied");
        assertEq(IFacetViews(address(vault)).autoYieldTrigger(), keeper, "second entry applied in the same transaction");
    }

    /// Batching cannot be used to act as someone else: a stranger's batch is refused per call.
    function test_batchDoesNotEscalate() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(BittyV1VaultDeFiFacet.useBittyAllowList, (false));

        vm.prank(stranger);
        vm.expectRevert();
        vault.multicall(calls);

        assertTrue(IFacetViews(address(vault)).usingBittyAllowList(), "unchanged");
    }

    /// A failing entry reverts the whole batch — no partial application.
    function test_batchIsAllOrNothing() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(BittyV1VaultDeFiFacet.useBittyAllowList, (false));
        // The second entry reverts (an over-long manager grant), taking the first with it.
        calls[1] = abi.encodeCall(
            BittyV1VaultDeFiFacet.setAssetManager, (keeper, type(uint64).max, PERM_YIELD | PERM_SUPPLY | PERM_INTENT)
        );

        vm.prank(owner);
        vm.expectRevert();
        vault.multicall(calls);

        assertTrue(IFacetViews(address(vault)).usingBittyAllowList(), "the first call was rolled back too");
        assertEq(IFacetViews(address(vault)).autoYieldTrigger(), address(0), "nothing applied");
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
        calls[0] = abi.encodeCall(BittyV1VaultDeFiFacet.useBittyAllowList, (false));
        calls[1] = abi.encodeCall(BittyV1VaultDeFiFacet.setAutoYieldTrigger, (keeper));

        _relay(address(vault), abi.encodeCall(vault.multicall, (calls)), owner);

        assertFalse(IFacetViews(address(vault)).usingBittyAllowList(), "relayed batch applied as the owner");
        assertEq(
            IFacetViews(address(vault)).autoYieldTrigger(),
            keeper,
            "both entries, one transaction, no ETH from the owner"
        );
    }

    /// The same suffix handling must not let the FORWARDER act on its own behalf.
    function test_relayedBatchFromANonOwnerSignerIsRefused() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(BittyV1VaultDeFiFacet.useBittyAllowList, (false));

        vm.prank(BITTY_FORWARDER);
        (bool ok,) = address(vault).call(abi.encodePacked(abi.encodeCall(vault.multicall, (calls)), stranger));
        assertFalse(ok, "a relayed batch signed by a stranger is refused");
        assertTrue(IFacetViews(address(vault)).usingBittyAllowList(), "unchanged");
    }
}
