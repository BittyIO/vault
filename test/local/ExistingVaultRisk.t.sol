// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {LegacySends} from "../helpers/LegacySends.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {VaultLocked} from "../../src/interfaces/IBittyV1Vault.sol";
import {BittyStorage} from "../../src/logic/BittyStorage.sol";
import {
    BITTY_GUARD,
    MIN_RISK_TIMELOCK,
    MAX_SEND_DAILY_ALLOWANCE,
    MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE,
    DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE
} from "../../src/logic/Constants.sol";

/**
 * A new vault no longer writes its starting allowances: an unset one reads as the new-vault default
 * because of a flag set at initialize. Vaults that already exist do not have that flag, and each
 * kind must read and ratchet exactly as before:
 *
 *   created before 1.0.9      — both allowances unset, read as the ceiling;
 *   created by 1.0.9          — sends off and the default loss allowance, WRITTEN at initialize.
 *
 * And a new vault, whose unset slots mean "off" and "the default", must still treat raising them as
 * a loosening.
 */
contract ExistingVaultRiskTest is Test {
    BittyV1Vault vault;
    address owner = makeAddr("owner");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        BittyV1Vault impl = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()));
        bytes memory init = abi.encodeCall(
            BittyV1Vault.initialize, (owner, makeAddr("gasWrapped"), false, address(0), 0, new bytes[](0))
        );
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));
    }

    function _risk(uint256 send, uint256 loss) internal {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(UNCHANGED, send, loss));
    }

    function _assertRisk(uint64 send, uint64 loss, string memory why) internal view {
        (uint64 timelock, uint64 s, uint64 l) = vault.riskSettings();
        assertEq(timelock, MIN_RISK_TIMELOCK, why);
        assertEq(s, send, why);
        assertEq(l, loss, why);
    }

    // ── a new vault writes nothing, and reads its defaults ───────────────────

    function test_aNewVaultWritesNeitherAllowance() public view {
        assertEq(vm.load(address(vault), bytes32(uint256(BittyStorage.VAULT_SLOT) + 4)), bytes32(0), "send slot");
        assertEq(vm.load(address(vault), bytes32(uint256(BittyStorage.VAULT_SLOT) + 5)), bytes32(0), "loss slot");
        _assertRisk(0, DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE, "the new-vault defaults");
    }

    /**
     * Judged against the allowance in force, not the empty slot: raising sends from unset is turning
     * them ON, and waits.
     */
    function test_aNewVaultRaisingFromUnsetWaitsOutTheTimelock() public {
        _risk(500, MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE);
        _assertRisk(0, DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE, "only scheduled");
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        _assertRisk(500, MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE, "a timelock later");
    }

    function test_aNewVaultLockedMayOnlyLowerFromTheDefault() public {
        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        vault.updateRisk(
            IBittyV1Owner.RiskSettings(UNCHANGED, UNCHANGED, DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE + 1)
        );
        _risk(UNCHANGED, DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE - 1);
        _assertRisk(0, DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE - 1, "lowered at once");
    }

    // ── created before 1.0.9: unset is the ceiling ───────────────────────────

    function test_aPre109VaultStillReadsTheCeiling() public {
        LegacySends.asCreatedBefore109(address(vault));
        _assertRisk(MAX_SEND_DAILY_ALLOWANCE, MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE, "unchanged by the upgrade");
    }

    function test_aPre109VaultLowersAtOnce() public {
        LegacySends.asCreatedBefore109(address(vault));
        _risk(100, 0);
        _assertRisk(100, 0, "a tightening from the ceiling lands at once");
    }

    function test_aPre109VaultReturningToTheCeilingWaits() public {
        LegacySends.asCreatedBefore109(address(vault));
        _risk(100, 100);
        _risk(MAX_SEND_DAILY_ALLOWANCE, MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE);
        _assertRisk(100, 100, "only scheduled");
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        _assertRisk(MAX_SEND_DAILY_ALLOWANCE, MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE, "a timelock later");
    }

    // ── created from 1.0.9 on: the written defaults stand ────────────────────

    function test_aWrittenDefaultsVaultReadsWhatWasWritten() public {
        LegacySends.asCreatedWithWrittenDefaults(address(vault));
        _assertRisk(0, DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE, "sends off, the default loss allowance");
    }

    function test_aWrittenDefaultsVaultTurningSendsOnWaits() public {
        LegacySends.asCreatedWithWrittenDefaults(address(vault));
        _risk(500, MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE);
        _assertRisk(0, DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE, "only scheduled");
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        _assertRisk(500, MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE, "a timelock later");
    }
}
