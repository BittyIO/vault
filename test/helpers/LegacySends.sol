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
 */
library LegacySends {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// VaultStorage: gasWrapped/flags, two mappings, then riskConfig =
    /// {timelock, sendDailyAllowance, marketTradeDailyLossAllowance}, one slot each.
    uint256 private constant SEND_ALLOWANCE_OFFSET = 4;
    uint256 private constant LOSS_ALLOWANCE_OFFSET = 5;

    /// Both allowances back to unset, which reads as the ceiling, as on a vault created before 1.0.9.
    function asCreatedBefore109(address vault) internal {
        bytes32 send = bytes32(uint256(BittyStorage.VAULT_SLOT) + SEND_ALLOWANCE_OFFSET);
        bytes32 loss = bytes32(uint256(BittyStorage.VAULT_SLOT) + LOSS_ALLOWANCE_OFFSET);
        require(uint64(uint256(vm.load(vault, send))) == ALLOWANCE_ZERO, "LegacySends: layout moved");
        require(
            uint64(uint256(vm.load(vault, loss))) == DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE,
            "LegacySends: layout moved"
        );
        vm.store(vault, send, bytes32(0));
        vm.store(vault, loss, bytes32(0));
    }
}
