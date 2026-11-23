// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {
    AmountIsZero,
    PaymentExceedsRiskCap,
    PaymentNotStableCoin,
    RiskAllowanceOutOfRange,
    RiskTimelockTooShort,
    TimelockNeedsLimits
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, MAX_DAILY_ALLOWANCE, NO_LIMIT} from "../../src/logic/Constants.sol";

/**
 * From 1.1.1 a vault that set nothing is open: no timelock, and no limit on either allowance. Regular
 * sends move any asset, any amount; trades and bridges are not priced (see MarketTradeGuard.t.sol
 * and Bridge.t.sol). Setting a number caps it from then on; {NO_LIMIT} opens it again.
 */
contract NoLimitTest is Test {
    BittyV1Vault vault;
    MockERC20 usdc;
    MockERC20 stray;
    WETH weth;

    address owner = makeAddr("owner");
    address payee = makeAddr("payee");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        weth = new WETH();
        BittyV1Vault impl = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        BittyV1Vault.initialize, (owner, address(weth), false, address(0), 0, new bytes[](0))
                    )
                ))
        );
        usdc = new MockERC20("USD Coin", "USDC", 6);
        MockGuard(BITTY_GUARD).setAsset(address(usdc), ASSET_STABLE_COIN);
        stray = new MockERC20("Stray", "STR", 18); // registered as nothing
        usdc.mint(address(vault), 10_000_000e6);
        stray.mint(address(vault), 1e30);
        vm.deal(address(this), 5 ether);
        weth.deposit{value: 5 ether}();
        weth.transfer(address(vault), 5 ether);
    }

    function _send(address asset, uint256 amount) internal {
        vm.prank(owner);
        vault.send(payee, asset, amount, new address[](0), new uint256[](0));
    }

    function _risk(uint256 timelock, uint256 send, uint256 loss) internal {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(timelock, send, loss));
    }

    // ── a new vault is open ─────────────────────────────────────────────────────

    function test_aNewVaultHasNoTimelockAndNoLimits() public view {
        (uint64 timelock, uint64 send, uint64 loss) = vault.riskSettings();
        assertEq(timelock, 0);
        assertEq(send, NO_LIMIT);
        assertEq(loss, NO_LIMIT);
    }

    function test_anyAssetAnyAmountMayBeSent() public {
        _send(address(usdc), 5_000_000e6); // over the 1,000,000 ceiling
        _send(address(stray), 1e30); // not a stablecoin, not registered
        _send(address(0), 1 ether); // ETH, unwrapped from the vault's WETH
        assertEq(usdc.balanceOf(payee), 5_000_000e6);
        assertEq(stray.balanceOf(payee), 1e30);
        assertEq(payee.balance, 1 ether);
    }

    function test_aBatchOfAnyAssetsMayBeSent() public {
        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (address(usdc), address(stray));
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (5_000_000e6, 1e30);
        vm.prank(owner);
        vault.batchSend(payee, assets, amounts, new address[][](2), new uint256[][](2));
        assertEq(stray.balanceOf(payee), 1e30);
    }

    function test_aZeroAmountIsStillRefused() public {
        vm.prank(owner);
        vm.expectRevert(AmountIsZero.selector);
        vault.send(payee, address(stray), 0, new address[](0), new uint256[](0));
    }

    function test_aZeroAmountInABatchIsStillRefused() public {
        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (address(usdc), address(stray));
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (1e6, 0);
        vm.prank(owner);
        vm.expectRevert(AmountIsZero.selector);
        vault.batchSend(payee, assets, amounts, new address[][](2), new uint256[][](2));
    }

    // ── capping, and opening again ──────────────────────────────────────────────

    /// A number is a tightening from no limit, so it lands at once, and sends are metered again.
    function test_settingANumberCapsAtOnce() public {
        _risk(UNCHANGED, 100, UNCHANGED);
        (, uint64 send,) = vault.riskSettings();
        assertEq(send, 100);

        vm.prank(owner);
        vm.expectRevert(PaymentExceedsRiskCap.selector);
        vault.send(payee, address(usdc), 101e6, new address[](0), new uint256[](0));
        vm.prank(owner);
        vm.expectRevert(PaymentNotStableCoin.selector);
        vault.send(payee, address(stray), 1, new address[](0), new uint256[](0));
    }

    /// Back to no limit is the loosest there is: the timelock goes to 0 with it, and all of it waits.
    function test_goingBackToNoLimitWaitsOutTheTimelock() public {
        _risk(1 days, 100, 100);
        _risk(0, NO_LIMIT, NO_LIMIT);
        (uint64 timelock, uint64 send, uint64 loss) = vault.riskSettings();
        assertEq(timelock, 1 days, "only scheduled");
        assertEq(send, 100, "only scheduled");
        assertEq(loss, 100, "only scheduled");
        assertEq(vault.pendingChanges().sendDailyAllowance, NO_LIMIT);

        vm.warp(block.timestamp + 1 days);
        (timelock, send, loss) = vault.riskSettings();
        assertEq(timelock, 0, "a day later");
        assertEq(send, NO_LIMIT, "a day later");
        assertEq(loss, NO_LIMIT, "a day later");
        _send(address(stray), 1e18);
    }

    // ── a timelock comes with limits ────────────────────────────────────────────

    /// A timelock with no limit protects the settings, not the money, so it is refused.
    function test_aTimelockNeedsBothAllowancesCapped() public {
        vm.startPrank(owner);
        vm.expectRevert(TimelockNeedsLimits.selector);
        vault.updateRisk(IBittyV1Owner.RiskSettings(1 days, UNCHANGED, UNCHANGED));
        vm.expectRevert(TimelockNeedsLimits.selector);
        vault.updateRisk(IBittyV1Owner.RiskSettings(1 days, 100, UNCHANGED));
        vm.expectRevert(TimelockNeedsLimits.selector);
        vault.updateRisk(IBittyV1Owner.RiskSettings(1 days, UNCHANGED, 100));
        vault.updateRisk(IBittyV1Owner.RiskSettings(1 days, 100, 100));
        vm.stopPrank();
        (uint64 timelock, uint64 send, uint64 loss) = vault.riskSettings();
        assertEq(timelock, 1 days, "protected at once");
        assertEq(send, 100);
        assertEq(loss, 100);
    }

    /// Limits without a timelock are allowed: guardrails, not protection.
    function test_limitsWithoutATimelockAreAllowed() public {
        _risk(UNCHANGED, 100, 100);
        (uint64 timelock, uint64 send, uint64 loss) = vault.riskSettings();
        assertEq(timelock, 0);
        assertEq(send, 100);
        assertEq(loss, 100);
    }

    /// While protected, no limit is refused: the timelock has to go to 0 first, or in the same call.
    function test_aProtectedVaultCannotGoBackToNoLimitAlone() public {
        _risk(1 days, 100, 100);
        vm.startPrank(owner);
        vm.expectRevert(TimelockNeedsLimits.selector);
        vault.updateRisk(IBittyV1Owner.RiskSettings(UNCHANGED, NO_LIMIT, UNCHANGED));
        vm.expectRevert(TimelockNeedsLimits.selector);
        vault.updateRisk(IBittyV1Owner.RiskSettings(UNCHANGED, UNCHANGED, NO_LIMIT));
        vm.stopPrank();
    }

    /// A waiting change counts: with no limit on its way, raising the timelock again is refused.
    function test_aTimelockCannotReturnWhileNoLimitIsOnItsWay() public {
        _risk(1 days, 100, 100);
        _risk(0, NO_LIMIT, NO_LIMIT); // all of it waits a day
        vm.prank(owner);
        vm.expectRevert(TimelockNeedsLimits.selector);
        vault.updateRisk(IBittyV1Owner.RiskSettings(2 days, UNCHANGED, UNCHANGED));

        // Setting numbers in the same call drops the waiting no limit, so that is allowed.
        _risk(2 days, 100, 100);
        vm.warp(block.timestamp + 2 days);
        (uint64 timelock, uint64 send, uint64 loss) = vault.riskSettings();
        assertEq(timelock, 2 days);
        assertEq(send, 100);
        assertEq(loss, 100);
    }

    /// A timelock below a day is refused: there would be no time to notice and lock.
    function test_aTimelockBelowADayIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(RiskTimelockTooShort.selector);
        vault.updateRisk(IBittyV1Owner.RiskSettings(1 hours, 100, 100));
    }

    function test_onlyTheCeilingOrNoLimitIsAccepted() public {
        vm.startPrank(owner);
        vm.expectRevert(RiskAllowanceOutOfRange.selector);
        vault.updateRisk(IBittyV1Owner.RiskSettings(UNCHANGED, uint256(MAX_DAILY_ALLOWANCE) + 1, UNCHANGED));
        vm.expectRevert(RiskAllowanceOutOfRange.selector);
        vault.updateRisk(IBittyV1Owner.RiskSettings(UNCHANGED, uint256(NO_LIMIT) - 1, UNCHANGED));
        vm.stopPrank();
    }

    /// Under a lock the loss allowance may still come down from no limit, as from any number.
    function test_aLockedVaultMayLowerTheLossAllowanceFromNoLimit() public {
        vm.prank(owner);
        vault.emergencyLock();
        _risk(UNCHANGED, UNCHANGED, 50);
        (,, uint64 loss) = vault.riskSettings();
        assertEq(loss, 50);
    }
}
