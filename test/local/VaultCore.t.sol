// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {NextReleaseVault} from "../helpers/NextReleaseVault.sol";
import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {OwnershipNotRenounceable, InvalidRelayedCalldata} from "../../src/interfaces/IBittyV1Vault.sol";
import {ImplementationNotRegistered, VaultNotNewer} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, BITTY_FORWARDER, MIN_RISK_TIMELOCK} from "../../src/logic/Constants.sol";

interface IFacet {
    function getAutoYieldings(address[] calldata assets) external view returns (address[] memory);
}

/**
 * The vault contract itself: ownership, upgrades, ETH handling, and the fallback into the facet.
 */
contract VaultCoreTest is Test {
    BittyV1Vault vault;
    BittyV1Vault impl;
    BittyV1VaultDeFiFacet facet;
    MockGuard guard;
    WETH gasWrapped;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);
        gasWrapped = new WETH();

        facet = new BittyV1VaultDeFiFacet();
        impl = new BittyV1Vault(address(facet));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, address(gasWrapped), false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setAsset(address(gasWrapped), 2);
    }

    // ── ownership ─────────────────────────────────────────────────────────────

    /**
     * One step. The two-step version looked like a defence and was not one: a stolen key nominates
     * itself and accepts in the same block, relayed, needing no ether. What it really bought was a
     * typo check, at the price of every honest handover costing two transactions. The timelock is
     * the defence, and it completes on its own - nobody has to accept.
     */
    function test_ownershipTransferTakesEffectAfterTheTimelockWithNoSecondCall() public {
        address next = makeAddr("next");
        vm.prank(owner);
        vault.transferOwnership(next);
        assertEq(vault.owner(), owner, "waits out the timelock, a day until the owner sets one");

        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        assertEq(vault.owner(), next, "and then it is done, with no second call");
    }

    /**
     * Abandoning is the same call, aimed at nobody: the delegates go with it, and the moment is
     * stamped so only payments already locked immutable by then may ever pay.
     */
    /**
     * Abandonment is gone, and {BittyV1Vault-foreverLock} is what replaced it. Throwing ownership
     * away froze the risk surface at the price of everything the vault was for — no conversion, no
     * unwinding by choice, no payment anywhere but where one had already been scheduled. The lock
     * freezes the same surface and leaves all of that working.
     */
    function test_theVaultCannotBeAbandoned() public {
        vm.prank(owner);
        vm.expectRevert(OwnershipNotRenounceable.selector);
        vault.transferOwnership(address(0));
        assertEq(vault.owner(), owner);
    }

    /**
     * OpenZeppelin's own renounceOwnership would zero the owner while skipping what abandoning has
     * to do — firing the delegates and stamping the moment that freezes the payable set. Shut, so
     * the only route is `transferOwnership(address(0))`, which does both.
     */
    function test_plainRenounceOwnershipIsShut() public {
        vm.prank(owner);
        vm.expectRevert(OwnershipNotRenounceable.selector);
        vault.renounceOwnership();
    }

    // ── upgrades ──────────────────────────────────────────────────────────────

    /**
     * Owner-authorised, but only to an implementation the GUARD has blessed. That is the difference
     * from a plain UUPS account: a compromised owner cannot install arbitrary code, only something
     * Bitty has already published.
     */
    /**
     * A vault may only move FORWARD. Blessing is not revoked the moment a release is superseded, so
     * without this a thief holding the key could roll a vault back onto an older blessed
     * implementation in one call — code that never heard of the locks, reads the lock level as a
     * slot it does not use, and hands ownership over instantly. Every protection in this contract
     * would be one downgrade away from gone.
     */
    function test_aVaultCannotBeDowngradedOrRePointedAtItself() public {
        BittyV1Vault sameVersion = new BittyV1Vault(address(facet));
        guard.setImpl(address(sameVersion), true);
        vm.prank(owner);
        vm.expectRevert(VaultNotNewer.selector);
        vault.upgrade(address(sameVersion));

        // Forward works, and then the build just left behind is refused as a target.
        BittyV1Vault next = new NextReleaseVault(address(facet));
        guard.setImpl(address(next), true);
        vm.prank(owner);
        vault.upgrade(address(next));

        vm.prank(owner);
        vm.expectRevert(VaultNotNewer.selector);
        vault.upgrade(address(sameVersion));
    }

    function test_upgradeOnlyToAGuardBlessedImplementation() public {
        BittyV1Vault rogue = new NextReleaseVault(address(facet));
        vm.prank(owner);
        vm.expectRevert(ImplementationNotRegistered.selector);
        vault.upgrade(address(rogue));

        guard.setImpl(address(rogue), true);
        vm.prank(owner);
        vault.upgrade(address(rogue));
    }

    function test_onlyOwnerMayUpgrade() public {
        BittyV1Vault next = new NextReleaseVault(address(facet));
        guard.setImpl(address(next), true);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        vault.upgrade(address(next));
    }

    // ── ETH ───────────────────────────────────────────────────────────────────

    /// ETH sent to the vault is wrapped on arrival, so it is never stranded as a bare balance.
    function test_receivedEthIsWrappedImmediately() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(vault).balance, 0, "no bare ETH left");
        assertEq(gasWrapped.balanceOf(address(vault)), 1 ether, "wrapped");
    }

    /// And anything that arrived some other way can be swept by anyone — it only helps the vault.
    function test_anyoneMaySweepStrandedEth() public {
        vm.deal(address(vault), 3 ether);
        vm.prank(makeAddr("passerby"));
        vault.wrapNative();
        assertEq(gasWrapped.balanceOf(address(vault)), 3 ether);
    }

    /// Unwrapping WETH must not re-enter the receive hook and wrap it straight back.
    function test_gasWrappedUnwrapDoesNotBounceBack() public {
        vm.deal(address(vault), 1 ether);
        vault.wrapNative();
        vm.prank(address(vault));
        gasWrapped.withdraw(0.5 ether);
        assertEq(address(vault).balance, 0.5 ether, "stayed unwrapped");
    }

    // ── the fallback ──────────────────────────────────────────────────────────

    /// Ordinary facet calls route through the fallback.
    function test_fallbackReachesTheFacet() public view {
        address[] memory one = new address[](1);
        one[0] = address(usdc);
        assertEq(IFacet(address(vault)).getAutoYieldings(one).length, 1);
    }

    /**
     * A relayed call shorter than a selector plus the ERC-2771 suffix would make the facet dispatch on
     * bytes taken from the appended address — a selector anyone can pick by grinding a vanity key,
     * rather than a function someone encoded a call to.
     */
    function test_shortRelayedCalldataIsRefused() public {
        vm.prank(BITTY_FORWARDER);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodePacked(bytes4(0xdeadbeef)));
        assertFalse(ok, "refused");
        assertEq(bytes4(ret), InvalidRelayedCalldata.selector);
    }

    /// The same short calldata from anyone else is not a relayed call, so the rule does not apply.
    function test_shortCalldataFromANonForwarderIsNotBlockedByThatRule() public {
        vm.prank(makeAddr("stranger"));
        (bool ok, bytes memory ret) = address(vault).call(abi.encodePacked(bytes4(0xdeadbeef)));
        assertFalse(ok, "still fails, but on dispatch");
        assertTrue(bytes4(ret) != InvalidRelayedCalldata.selector, "not the relayed-calldata guard");
    }

    // ── initialization ────────────────────────────────────────────────────────

    function test_cannotInitializeTwice() public {
        vm.expectRevert();
        vault.initialize(owner, address(gasWrapped), false, address(0), 0, new bytes[](0));
    }

    /// The implementation itself is not usable as a vault — initializers are disabled on it.
    function test_theImplementationCannotBeInitialized() public {
        vm.expectRevert();
        impl.initialize(makeAddr("squatter"), address(gasWrapped), false, address(0), 0, new bytes[](0));
    }

    function test_immutablesAreWired() public view {
        assertEq(vault.DEFI_FACET(), address(facet));
        assertEq(vault.trustedForwarder(), BITTY_FORWARDER);
    }

    function test_theVaultReportsTheWethItUnwrapsThrough() public view {
        assertEq(vault.gasWrappedAddress(), address(gasWrapped), "the app needs this to present WETH as ETH");
    }
}
