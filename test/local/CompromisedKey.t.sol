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
import {AutoYield, IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, MIN_RISK_TIMELOCK, PERM_YIELD, PERM_SUPPLY, PERM_INTENT} from "../../src/logic/Constants.sol";

/*
 * The capabilities these tests appoint a manager for: the jobs a managed vault is actually given —
 * yield, lending and the intent orders it signs — and NOT trading at market, which the owner has to
 * grant by name. See {PERM_YIELD} and the note above it.
 */
uint32 constant MANAGER_PERMS = PERM_YIELD | PERM_SUPPLY | PERM_INTENT;

/**
 * The whole point of the machinery, told as one story: the owner's key is compromised, the owner
 * locks the vault for ever, and goes on using it.
 *
 * This used to end in a renounce — ownership thrown away, delegates fired, the vault left to pay its
 * standing payments with nobody holding a key. That worked, and it cost the owner everything the
 * vault was for: a position entered before the renounce could never be chosen out of, a balance in
 * the wrong token could never be converted, and the only money that ever moved again was whatever
 * had been scheduled in advance. The owner was protected from the thief by being locked out
 * alongside them.
 *
 * {BittyV1Vault-foreverLock} is the better trade, and this file is the argument for it. The key
 * stays live and so does the owner: they still pay the destinations they vetted, still push the
 * standing payments, still sell holdings into stablecoins through a limit order, still unwind every
 * position. What they can never do again — and therefore what the thief can never do either — is
 * add risk. No new destination, no looser limit, no new delegate, no handover, no new code, and
 * nothing taken away either, since removing an option the owner still has would be an attack in its
 * own right.
 *
 * So the test of the design is not "is the attacker shut out", which no lock can achieve while they
 * hold the key. It is: can the attacker profit, and can the owner still live in their vault. The
 * answers below are no and yes.
 */
contract CompromisedKeyTest is Test {
    BittyV1Vault vault;
    BittyV1VaultDeFiFacet facet;
    MockGuard guard;
    MockERC20 usdc;
    MockLendingProtocol sky;
    MockERC20 weth; // something the rescue payment is NOT denominated in

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
    uint256 coldId;

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
        vm.warp(START - MIN_RISK_TIMELOCK);
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
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setAsset(address(weth), ASSET_STABLE_COIN);
        guard.setProtocol(address(sky), LENDING_ID);
        usdc.mint(address(vault), 10_000e6);
        weth.mint(address(vault), 5e18);

        // A vault in normal service: a trading delegate, a keeper, and a destination the owner
        // vetted long before anything went wrong.
        vm.startPrank(owner);
        _f().setAssetManager(manager, uint64(block.timestamp + 365 days), MANAGER_PERMS);
        _f().setAutoYieldTrigger(keeper);
        coldId = vault.addWhitelistedRecipient(heir);
        vm.stopPrank();
        vm.warp(START); // the grant and the destination have waited out a new vault's timelock
    }

    /**
     * The compromise, and the answer to it. One call, by the owner, with no preparation and no way
     * back — because anything reversible is reversible by whoever else holds the key, and anything
     * that had to be queued could be cancelled inside the queue.
     */
    function test_theForeverLockIsOneCallAndCannotBeUndone() public {
        vm.prank(owner);
        vault.foreverLock(coldId);
        assertEq(vault.lockLevel(), 2);

        vm.prank(owner);
        vm.expectRevert();
        vault.unlock();
        assertEq(vault.lockLevel(), 2, "no key undoes this, including the owner's own");
    }

    /// The delegate the attacker inherits is held to the same line: it may unwind, never invest.
    function test_theInheritedDelegateCanOnlyBringValueHome() public {
        vm.prank(manager);
        _f().deposit(address(sky), address(usdc), 1_000e6);

        vm.prank(owner);
        vault.foreverLock(coldId);

        vm.prank(manager);
        vm.expectRevert();
        _f().deposit(address(sky), address(usdc), 1_000e6);

        vm.prank(manager);
        _f().withdraw(address(sky), address(usdc), 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6, "home, where the standing payments are paid from");
    }

    /// And the keeper's sweep stops, because putting idle money to work is adding a position.
    function test_theInheritedKeeperStops() public {
        vm.prank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(sky)}));
        vm.prank(owner);
        vault.foreverLock(coldId);

        vm.prank(keeper);
        vm.expectRevert();
        _f().autoYield(address(usdc));
    }

    /**
     * The half the renounce could never do. A locked vault's holdings are not stuck in whatever
     * token they happened to be in: the owner signs a limit order, solvers compete to fill it, and
     * the proceeds arrive here in the asset the payments are denominated in. Buying anything else is
     * refused, so the open trade is a conversion and not an exit.
     */
    function test_theOwnerCanStillSellHoldingsIntoStablecoins() public {
        MockERC20 shiny = new MockERC20("Shiny", "SHINY", 18);
        guard.setAsset(address(shiny), 2);
        vm.prank(owner);
        _f().updateAssets(_one(address(shiny)), new address[](0));

        vm.prank(owner);
        vault.foreverLock(coldId);

        assertTrue(
            _f().isOffchainOrderAuthorized(owner, address(weth), address(usdc), 1e18), "into the payments' asset: yes"
        );
        assertFalse(
            _f().isOffchainOrderAuthorized(owner, address(usdc), address(shiny), 1e6), "out into something else: no"
        );
    }

    /**
     * The gas budget closes with the lock. A thief cannot otherwise spend the vault's own money on
     * relaying the calls that remain open — which costs them nothing, pays Bitty rather than
     * themselves, and would drain the budget day after day. Relayed calls still work; the submitter
     * pays, from an address the thief does not hold.
     */
    function test_theStolenKeyCannotSpendTheVaultsGasBudget() public {
        vm.prank(owner);
        vault.foreverLock(coldId);
        assertEq(vault.gasBudgetRemaining(), 0);
    }
}
