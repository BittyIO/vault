// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {
    IBittyV1Vault,
    NotPayoutOperator,
    OnlyImmutablePayableAfterRenounce
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * The whole point of the machinery, told as one story: the owner's key is compromised, the owner
 * renounces, and the vault keeps paying the person it was always meant to pay.
 *
 * Renouncing is the last thing an owner can do with a key they no longer trust. It is worth having
 * only if two things hold afterwards. The key must buy the attacker nothing — including through any
 * delegate the owner had appointed before the compromise, which the attacker inherits. And the
 * beneficiary must still be paid, with nobody left holding a key to make that happen.
 */
contract CompromisedKeyTest is Test {
    BittyV1Vault vault;
    BittyV1VaultDeFiFacet facet;
    MockGuard guard;
    MockERC20 usdc;
    MockLendingProtocol sky;

    address owner = makeAddr("owner"); // the key that gets compromised
    address manager = makeAddr("manager"); // appointed before the compromise
    address subOwner = makeAddr("subOwner");
    address keeper = makeAddr("keeper"); // the auto-yield trigger
    address heir = makeAddr("heir"); // the rescue payment's recipient
    address stranger = makeAddr("stranger"); // no privileges, ever
    address gasWrapped = makeAddr("gasWrapped");

    uint64 constant START = 1_000_000;
    uint64 constant SUB_GRANT = 90 days;

    uint256 subId;
    uint256 rescueId;

    /// @dev A bare expectRevert would pass on any revert at all, including the wrong one.
    function _notOwner(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, who);
    }

    function _f() internal view returns (BittyV1VaultDeFiFacet) {
        return BittyV1VaultDeFiFacet(payable(address(vault)));
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _one(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function setUp() public {
        vm.warp(START);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)))
                ))
        );

        usdc = new MockERC20("USD Coin", "USDC", 6);
        sky = new MockLendingProtocol();
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setProtocol(address(sky), LENDING_ID);
        usdc.mint(address(vault), 10_000e6);

        // A vault in normal service: a trading delegate, a keeper, and a standing payment to the
        // person this vault exists for.
        vm.startPrank(owner);
        _f().setAssetManager(manager, 0);
        _f().setAutoYieldTrigger(keeper);
        rescueId = vault.addScheduledPayment(
            IBittyV1Vault.ScheduledPayment({
                recipient: heir,
                remainingPaymentCount: type(uint256).max,
                isImmutable: true,
                payWithInsufficientBalance: false,
                trigger: address(0),
                assetAddress: address(usdc),
                amount: 500e6,
                startTimestamp: block.timestamp,
                paymentInterval: 30 days
            })
        );
        vm.stopPrank();
    }

    /// Everything is live before the compromise, so the test that follows is about what CHANGES.
    function test_theVaultWorksBeforeTheCompromise() public {
        vm.prank(manager);
        _f().deposit(address(sky), address(usdc), 1_000e6);

        vault.payScheduled(rescueId, new address[](0));
        assertEq(usdc.balanceOf(heir), 500e6, "the heir is being paid");
    }

    /**
     * The compromise. The owner renounces, naming the immutable payment as the rescue target, and the
     * key that was stolen is worth nothing from that block on — including the delegates it inherited.
     */
    function test_renouncingDisarmsTheStolenKeyAndEveryDelegateItHeld() public {
        vm.prank(owner);
        vault.renounceVaultOwnership(rescueId);
        assertEq(vault.owner(), address(0), "ownerless");

        // The attacker holds the owner key. It opens nothing.
        vm.startPrank(owner);
        vm.expectRevert(NotPayoutOperator.selector);
        vault.send(owner, address(usdc), 1e6, new address[](0), new uint256[](0));
        vm.expectRevert(_notOwner(owner));
        vault.transferOwnership(owner);
        vm.expectRevert(_notOwner(owner));
        _f().setAssetManager(owner, 0);
        vm.stopPrank();

        // The delegates appointed BEFORE the compromise are the subtle part: the attacker inherits
        // them, so renounce fires them rather than leaving a second key alive on an ownerless vault.
        (address live,, address pending,) = _f().getAssetManagerSettings();
        assertEq(live, address(0), "asset manager fired");
        assertEq(pending, address(0), "and nothing queued behind them");
        assertEq(_f().autoYieldTrigger(), address(0), "auto-yield trigger cleared");

        vm.prank(manager);
        vm.expectRevert(_notOwner(manager));
        _f().deposit(address(sky), address(usdc), 100e6);

        assertEq(usdc.balanceOf(owner), 0, "the stolen key extracted nothing");
        assertEq(usdc.balanceOf(manager), 0);
    }

    /// The other half: the beneficiary keeps being paid, by anyone, forever, with no key in existence.
    function test_theHeirKeepsBeingPaidWithNoKeyLeft() public {
        vm.prank(owner);
        vault.renounceVaultOwnership(rescueId);

        for (uint256 i; i < 4; ++i) {
            vm.warp(START + (i + 1) * 30 days);
            vm.prank(stranger); // a stranger pushes it through; nobody is privileged
            vault.payScheduled(rescueId, new address[](0));
        }
        assertEq(usdc.balanceOf(heir), 4 * 500e6, "paid four times after the vault lost its owner");
    }

    /**
     * The attacker cannot leave itself a DELAYED backdoor either: an immutable payment queued inside
     * its protection window just before the renounce is invisible to the rescue check and locks only
     * after — when nobody is left who could remove it. The payable set is frozen at the renounce, so
     * such a payment must never pay, however long the attacker waits.
     */
    function test_paymentQueuedInsideItsWindowBeforeRenounceNeverPays() public {
        address attacker = makeAddr("attacker");
        uint256 unchanged = type(uint256).max;

        // The compromised key queues a drain-everything payment to itself, still inside the protection
        // window (raising the window is a tightening, so it applies immediately).
        vm.startPrank(owner);
        vault.updatePaymentRisk(IBittyV1Owner.PaymentRisk(1 days, unchanged, unchanged, unchanged));
        uint256 evilId = vault.addScheduledPayment(
            IBittyV1Vault.ScheduledPayment({
                recipient: attacker,
                remainingPaymentCount: type(uint256).max,
                isImmutable: true,
                payWithInsufficientBalance: true,
                trigger: attacker,
                assetAddress: address(usdc),
                amount: 10_000e6,
                startTimestamp: block.timestamp,
                paymentInterval: 0
            })
        );
        vm.stopPrank();

        // The legitimate holder renounces; the rescue payment is locked, so the renounce succeeds.
        vm.prank(owner);
        vault.renounceVaultOwnership(rescueId);

        // One protection window later the attacker's payment would be "locked immutable" — but it was
        // not locked AT the renounce, so it stays unpayable forever.
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(attacker);
        vm.expectRevert(OnlyImmutablePayableAfterRenounce.selector);
        vault.payScheduled(evilId, new address[](0));
        assertEq(usdc.balanceOf(attacker), 0, "the backdoor paid nothing");

        // While the heir — locked before the renounce — is still paid.
        vault.payScheduled(rescueId, new address[](0));
        assertEq(usdc.balanceOf(heir), 500e6, "the rescue payment survived");
    }

    /// Nothing else can be paid — the rescue payment is the only way value leaves an ownerless vault.
    function test_onlyTheRescuePaymentSurvivesRenounce() public {
        vm.prank(owner);
        uint256 ordinary = vault.addScheduledPayment(
            IBittyV1Vault.ScheduledPayment({
                recipient: stranger,
                remainingPaymentCount: 5,
                isImmutable: false,
                payWithInsufficientBalance: false,
                trigger: address(0),
                assetAddress: address(usdc),
                amount: 100e6,
                startTimestamp: block.timestamp,
                paymentInterval: 0
            })
        );

        vm.prank(owner);
        vault.renounceVaultOwnership(rescueId);

        vm.expectRevert(OnlyImmutablePayableAfterRenounce.selector);
        vault.payScheduled(ordinary, new address[](0));
        assertEq(usdc.balanceOf(stranger), 0, "a mutable payment cannot pay after renounce");
    }
}
