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
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
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
    address weth = makeAddr("weth");

    uint64 constant START = 1_000_000;
    uint64 constant SUB_GRANT = 90 days;

    uint256 subId;
    BittyV1SubVault sub;
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
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl), abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0))
                ))
        );

        usdc = new MockERC20("USD Coin", "USDC", 6);
        sky = new MockLendingProtocol();
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setProtocol(address(sky), LENDING_ID);
        usdc.mint(address(vault), 10_000e6);

        // A vault in normal service: a trading delegate, a keeper, a funded sub account, and a
        // standing payment to the person this vault exists for.
        vm.startPrank(owner);
        _f().setAssetManager(manager, 0);
        _f().setAutoYieldTrigger(keeper);
        (subId,) = vault.createSubVault(subOwner, false, START + SUB_GRANT);
        sub = BittyV1SubVault(payable(_subAccount()));
        vault.fundSubVault(subId, _one(address(usdc)), _one(2_000e6));
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

    function _subAccount() internal view returns (address account) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = subId;
        (address[] memory accounts,,,,) = vault.getSubVault(ids);
        account = accounts[0];
    }

    /// Everything is live before the compromise, so the test that follows is about what CHANGES.
    function test_theVaultWorksBeforeTheCompromise() public {
        vm.prank(manager);
        _f().deposit(address(sky), address(usdc), 1_000e6);

        vm.prank(subOwner);
        BittyV1VaultDeFiFacet(payable(address(sub))).deposit(address(sky), address(usdc), 500e6);

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
        vault.createSubVault(owner, false, START + SUB_GRANT);
        vm.expectRevert(_notOwner(owner));
        vault.transferOwnership(owner);
        vm.expectRevert(_notOwner(owner));
        _f().setAssetManager(owner, 0);
        vm.expectRevert(_notOwner(owner));
        vault.recallFromSubVault(subId, _one(address(usdc)), _one(2_000e6));
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

    /**
     * The sub account outlives the renounce, then winds itself up. Its grant was bounded at creation —
     * it has to be, a sub cannot exist without a deadline — so once it lapses the unwind and the trip
     * home both go permissionless, and the recovered value leaves through the rescue payment.
     */
    function test_theSubAccountWindsItselfUpAndTheValueReachesTheHeir() public {
        vm.prank(subOwner);
        BittyV1VaultDeFiFacet(payable(address(sub))).deposit(address(sky), address(usdc), 2_000e6);

        vm.prank(owner);
        vault.renounceVaultOwnership(rescueId);

        // Still inside its grant: the sub carries on, and strangers stay out.
        vm.prank(stranger);
        vm.expectRevert(_notOwner(stranger));
        BittyV1VaultDeFiFacet(payable(address(sub))).withdraw(address(sky), address(usdc), 1);

        vm.warp(START + SUB_GRANT);

        // Lapsed. Anyone can unwind the position and send it home - no key exists to ask.
        vm.startPrank(stranger);
        BittyV1VaultDeFiFacet(payable(address(sub))).withdraw(address(sky), address(usdc), 2_000e6);
        sub.returnToVault(_one(address(usdc)), _one(2_000e6));
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(sub)), 0, "the sub is empty");

        // And that recovered value has exactly one way out of the parent.
        uint256 before = usdc.balanceOf(heir);
        vm.warp(START + SUB_GRANT + 30 days);
        vm.prank(stranger);
        vault.payScheduled(rescueId, new address[](0));
        assertEq(usdc.balanceOf(heir), before + 500e6, "it reached the heir");
        assertEq(usdc.balanceOf(stranger), 0, "and never the person who moved it");
    }
}
