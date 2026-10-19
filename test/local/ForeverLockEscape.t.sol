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
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {NoEscapeRecipient} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, MIN_RISK_TIMELOCK} from "../../src/logic/Constants.sol";

interface IDeposit {
    function deposit(address protocol, address asset, uint256 amount) external;
}

/**
 * The forever lock needs a way out. Once it is engaged nothing can be added, so a whitelisted
 * recipient the vault can already pay is the only route money ever leaves by again. The owner names
 * one, and a lock that would leave none is refused rather than sealing the money in.
 */
contract ForeverLockEscapeTest is Test {
    BittyV1Vault vault;
    MockERC20 usdc;
    MockERC20 weth;
    MockLendingProtocol lending;

    address owner = makeAddr("owner");
    address cold = makeAddr("cold");

    uint256 constant UNCHANGED = type(uint256).max;
    uint64 constant TIMELOCK = 3 days;
    /**
     * Every test starts here. Kept as a constant because under via-IR a local copy of
     * `block.timestamp` is re-read after a warp rather than remembered.
     */
    uint256 constant T0 = 1_000_000;

    uint256 coldId;

    function setUp() public {
        vm.warp(T0 - MIN_RISK_TIMELOCK);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        MockGuard guard = MockGuard(BITTY_GUARD);
        BittyV1Vault impl = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()));
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        BittyV1Vault.initialize, (owner, address(weth), false, address(0), 0, new bytes[](0))
                    )
                ))
        );
        usdc = new MockERC20("USD Coin", "USDC", 6);
        lending = new MockLendingProtocol();
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setProtocol(address(lending), LENDING_ID);
        usdc.mint(address(vault), 1_000e6);
        weth.mint(address(vault), 5e18);

        // One destination vetted before anything goes wrong, then a timelock on what follows.
        vm.startPrank(owner);
        coldId = vault.addWhitelistedRecipient(cold);
        vm.warp(T0);
        vault.updateRisk(IBittyV1Owner.RiskSettings(TIMELOCK, UNCHANGED, UNCHANGED));
        vm.stopPrank();
    }

    function _refused(uint256 id) internal {
        vm.prank(owner);
        vm.expectRevert(NoEscapeRecipient.selector);
        vault.foreverLock(id);
        assertEq(vault.lockLevel(), 0, "and the vault is not locked");
    }

    // ── refused ───────────────────────────────────────────────────────────────

    function test_refusedForAnEntryThatDoesNotExist() public {
        _refused(99);
    }

    function test_refusedForAnEntryStillInItsWindow() public {
        vm.prank(owner);
        uint256 fresh = vault.addWhitelistedRecipient(makeAddr("fresh"));
        _refused(fresh);
    }

    function test_refusedForAnEntryWhoseRemovalLanded() public {
        vm.prank(owner);
        vault.removeWhitelistedRecipients(_ids(coldId));
        vm.warp(T0 + TIMELOCK);
        _refused(coldId);
    }

    function test_refusedForAnEntryAnEarlierLockVoided() public {
        vm.prank(owner);
        uint256 swept = vault.addWhitelistedRecipient(makeAddr("swept"));
        vm.startPrank(owner);
        vault.emergencyLock();
        vault.unlock();
        vm.stopPrank();
        vm.warp(T0 + TIMELOCK * 10);
        _refused(swept);
    }

    /**
     * Paying the vault moves nothing, so its own address is no way out however long it has stood.
     */
    function test_refusedForTheVaultItself() public {
        vm.prank(owner);
        uint256 self = vault.addWhitelistedRecipient(address(vault));
        vm.warp(T0 + TIMELOCK);
        _refused(self);
    }

    // ── allowed, and what it keeps ────────────────────────────────────────────

    /**
     * A removal still waiting is no obstacle: the lock voids it, so the named entry stays payable.
     */
    function test_aWaitingRemovalOfTheNamedEntryIsVoidedByTheLock() public {
        vm.prank(owner);
        vault.removeWhitelistedRecipients(_ids(coldId));
        vm.prank(owner);
        vault.foreverLock(coldId);
        assertEq(vault.lockLevel(), 2);

        vm.warp(T0 + 365 days);
        vm.prank(owner);
        vault.sendToWhitelistedRecipient(coldId, address(usdc), 1e6, new address[](0), new uint256[](0));
        assertEq(usdc.balanceOf(cold), 1e6);
    }

    /**
     * The point of it: after the lock, every kind of holding still gets out — a stablecoin, a
     * non-stable token, and a position, which the payout pulls back on the way.
     */
    function test_afterTheLockEverythingStillGetsOut() public {
        vm.prank(owner);
        IDeposit(address(vault)).deposit(address(lending), address(usdc), 400e6);
        vm.prank(owner);
        vault.foreverLock(coldId);

        address[] memory from = new address[](1);
        from[0] = address(lending);
        uint256[] memory pull = new uint256[](1);
        pull[0] = 400e6;
        vm.startPrank(owner);
        vault.sendToWhitelistedRecipient(coldId, address(usdc), 1_000e6, from, pull);
        vault.sendToWhitelistedRecipient(coldId, address(weth), 5e18, new address[](0), new uint256[](0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(cold), 1_000e6, "the stablecoin, the position included");
        assertEq(weth.balanceOf(cold), 5e18, "the non-stable token");
        assertEq(usdc.balanceOf(address(vault)) + weth.balanceOf(address(vault)), 0, "nothing left behind");
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = id;
    }
}
