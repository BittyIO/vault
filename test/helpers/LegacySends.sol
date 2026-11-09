// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {BittyStorage} from "../../src/logic/BittyStorage.sol";
import {ALLOWANCE_ZERO, DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE} from "../../src/logic/Constants.sol";

/**
 * For suites that test regular sends, or market trades against the allowance ceiling. A vault created since 1.0.9 starts with sends off,
 * and an owner turns them on by waiting out the timelock, which would move every timestamp those
 * suites pin. A vault created before 1.0.9 never wrote the allowance, and an unset allowance reads
 * as the largest there is. This puts a vault in that state, which is a real one: every upgraded
 * vault is in it.
 *
 * A new vault leaves both allowances unset too and reads them as its defaults through
 * {VaultStorage.unsetRiskIsDefault}. A vault created before 1.0.10 has it false, so the state
 * here is: both allowances unset, the flag off.
 */
library LegacySends {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// VaultStorage: gasWrapped/flags, two mappings, then riskConfig =
    /// {timelock, sendDailyAllowance, marketTradeDailyLossAllowance}, one slot each.
    uint256 private constant SEND_ALLOWANCE_OFFSET = 4;
    uint256 private constant LOSS_ALLOWANCE_OFFSET = 5;
    /// Slot 0: gasWrapped (bytes 0-19), isInitialized (20), ownAllowListActive (21),
    /// unsetRiskIsDefault (22), counting from the low-order end.
    uint256 private constant UNSET_IS_DEFAULT_BIT = 22 * 8;

    /// Both allowances unset and read as the ceiling, as on a vault created before 1.0.9.
    function asCreatedBefore109(address vault) internal {
        bytes32 flags = BittyStorage.VAULT_SLOT;
        bytes32 send = bytes32(uint256(BittyStorage.VAULT_SLOT) + SEND_ALLOWANCE_OFFSET);
        bytes32 loss = bytes32(uint256(BittyStorage.VAULT_SLOT) + LOSS_ALLOWANCE_OFFSET);
        uint256 word = uint256(vm.load(vault, flags));
        require((word >> UNSET_IS_DEFAULT_BIT) & 0xff == 1, "LegacySends: layout moved");
        require(uint64(uint256(vm.load(vault, send))) == 0, "LegacySends: layout moved");
        require(uint64(uint256(vm.load(vault, loss))) == 0, "LegacySends: layout moved");
        vm.store(vault, send, bytes32(0));
        vm.store(vault, loss, bytes32(0));
        vm.store(vault, flags, bytes32(word & ~(uint256(0xff) << UNSET_IS_DEFAULT_BIT)));
    }

    /// The same, as on a vault created by 1.0.9: the defaults written, the flag off.
    function asCreatedWithWrittenDefaults(address vault) internal {
        asCreatedBefore109(vault);
        vm.store(
            vault, bytes32(uint256(BittyStorage.VAULT_SLOT) + SEND_ALLOWANCE_OFFSET), bytes32(uint256(ALLOWANCE_ZERO))
        );
        vm.store(
            vault,
            bytes32(uint256(BittyStorage.VAULT_SLOT) + LOSS_ALLOWANCE_OFFSET),
            bytes32(uint256(DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE))
        );
    }
}
