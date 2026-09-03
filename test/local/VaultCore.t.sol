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
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    OwnershipNotRenounceable,
    PendingOwnerIsPayoutOperator,
    InvalidRelayedCalldata,
    NoRescueTarget
} from "../../src/interfaces/IBittyV1Vault.sol";
import {ImplementationNotRegistered} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, BITTY_FORWARDER} from "../../src/logic/Constants.sol";

interface IFacet {
    function getAutoYieldings(address[] calldata assets) external view returns (address[] memory);
}

/**
 * The vault contract itself: ownership, upgrades, ETH handling, and the fallback into the facet.
 */
contract VaultCoreTest is Test {
    BittyV1Vault vault;
    BittyV1Vault impl;
    BittyV1SubVault subImpl;
    BittyV1VaultDeFiFacet facet;
    MockGuard guard;
    WETH weth;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);
        weth = new WETH();

        facet = new BittyV1VaultDeFiFacet();
        subImpl = new BittyV1SubVault(address(facet));
        impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, address(weth), false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setAsset(address(weth), 2);
    }

    // ── ownership ─────────────────────────────────────────────────────────────

    /// Two-step, so a typo in the new owner cannot orphan the vault.
    function test_ownershipTransferIsTwoStep() public {
        address next = makeAddr("next");
        vm.prank(owner);
        vault.transferOwnership(next);
        assertEq(vault.owner(), owner, "not yet");

        vm.prank(next);
        vault.acceptOwnership();
        assertEq(vault.owner(), next, "only once accepted");
    }

    /**
     * A payout operator proposes payments for the owner to approve. If they could also BE the owner
     * they would approve their own proposals, and the whole two-party check collapses.
     */
    function test_aPayoutOperatorCannotBecomeTheOwner() public {
        vm.startPrank(owner);
        vault.updatePayoutOperator(operator, true);
        vault.transferOwnership(operator);
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert(PendingOwnerIsPayoutOperator.selector);
        vault.acceptOwnership();
    }

    /**
     * OpenZeppelin's renounceOwnership would zero the owner while skipping the checks renounce must
     * clear — a locked rescue payment and no open subs. Shut, so the only route is the one that
     * enforces them; otherwise one call bricks the vault with the funds frozen inside.
     */
    function test_plainRenounceOwnershipIsShut() public {
        vm.prank(owner);
        vm.expectRevert(OwnershipNotRenounceable.selector);
        vault.renounceOwnership();
    }

    function test_renounceNeedsARescueTarget() public {
        vm.prank(owner);
        vm.expectRevert(NoRescueTarget.selector);
        vault.renounceVaultOwnership(1);
    }

    // ── upgrades ──────────────────────────────────────────────────────────────

    /**
     * Owner-authorised, but only to an implementation the GUARD has blessed. That is the difference
     * from a plain UUPS account: a compromised owner cannot install arbitrary code, only something
     * Bitty has already published.
     */
    function test_upgradeOnlyToAGuardBlessedImplementation() public {
        BittyV1Vault rogue = new BittyV1Vault(address(facet), address(subImpl));
        vm.prank(owner);
        vm.expectRevert(ImplementationNotRegistered.selector);
        vault.upgrade(address(rogue));

        guard.setImpl(address(rogue), true);
        vm.prank(owner);
        vault.upgrade(address(rogue));
    }

    function test_onlyOwnerMayUpgrade() public {
        BittyV1Vault next = new BittyV1Vault(address(facet), address(subImpl));
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
        assertEq(weth.balanceOf(address(vault)), 1 ether, "wrapped");
    }

    /// And anything that arrived some other way can be swept by anyone — it only helps the vault.
    function test_anyoneMaySweepStrandedEth() public {
        vm.deal(address(vault), 3 ether);
        vm.prank(makeAddr("passerby"));
        vault.ETHToWETH();
        assertEq(weth.balanceOf(address(vault)), 3 ether);
    }

    /// Unwrapping WETH must not re-enter the receive hook and wrap it straight back.
    function test_wethUnwrapDoesNotBounceBack() public {
        vm.deal(address(vault), 1 ether);
        vault.ETHToWETH();
        vm.prank(address(vault));
        weth.withdraw(0.5 ether);
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
        vault.initialize(owner, address(weth), false, address(0), 0);
    }

    /// The implementation itself is not usable as a vault — initializers are disabled on it.
    function test_theImplementationCannotBeInitialized() public {
        vm.expectRevert();
        impl.initialize(makeAddr("squatter"), address(weth), false, address(0), 0);
    }

    function test_immutablesAreWired() public view {
        assertEq(vault.DEFI_FACET(), address(facet));
        assertEq(vault.SUB_VAULT_IMPL(), address(subImpl));
        assertEq(vault.trustedForwarder(), BITTY_FORWARDER);
    }

    // ── small reads the app depends on ────────────────────────────────────────

    function test_theVaultReportsWhoItsPayoutOperatorsAre() public {
        address op = makeAddr("payoutOperator");
        assertFalse(vault.isPayoutOperator(op), "nobody yet");

        vm.prank(owner);
        vault.updatePayoutOperator(op, true);
        assertTrue(vault.isPayoutOperator(op), "named");

        vm.prank(owner);
        vault.updatePayoutOperator(op, false);
        assertFalse(vault.isPayoutOperator(op), "removed");
    }

    function test_theVaultReportsTheWethItUnwrapsThrough() public view {
        assertEq(vault.wethAddress(), address(weth), "the app needs this to present WETH as ETH");
    }
}
