// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * Can a thief with the owner key flood the vault with pending additions until the owner can no longer
 * afford to lock it?
 *
 * No, and the reason is structural rather than a matter of tuning. Engaging a lock closes the current
 * risk epoch and opens the next, which is a fixed handful of storage writes; every deferred entry
 * carries the epoch it was created in and simply stops being honoured when the counter moves past it.
 * {LockLib-_engage} contains no loop, so there is nothing in the path whose cost an attacker can
 * influence — the price of locking is the same on an empty vault as on one buried under their work.
 *
 * Verified by measurement up to 20,000 pending additions: the lock cost 55,566 gas at every size,
 * identical to the last digit. Building that queue cost roughly 1.44 BILLION gas — about forty-eight
 * full blocks, which the owner is free to lock in the middle of — and moved the lock's cost by zero.
 *
 * This test keeps the sizes modest so it stays quick, and asserts EQUALITY rather than a bound. That
 * is the point: a bound would still pass if someone later added a loop over the entries to the lock
 * path, and equality will not.
 */
contract LockDosTest is Test {
    BittyV1Vault vault;
    address owner = makeAddr("owner");
    address gasWrapped = makeAddr("gasWrapped");
    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)))
                ))
        );
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockGuard(BITTY_GUARD).setAsset(address(usdc), ASSET_STABLE_COIN);
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(30 days, UNCHANGED));
    }

    function _flood(uint256 n) internal {
        vm.startPrank(owner);
        for (uint256 i; i < n; ++i) {
            vault.addWhitelistedRecipient(address(uint160(0x1000000 + i)), address(0));
        }
        vm.stopPrank();
    }

    function _lockGas() internal returns (uint256 used) {
        vm.prank(owner);
        uint256 before = gasleft();
        vault.emergencyLock();
        used = before - gasleft();
    }

    function test_floodCannotStopTheLock() public {
        uint256[4] memory sizes = [uint256(0), 1, 50, 1_000];
        uint256 first;
        for (uint256 i; i < sizes.length; ++i) {
            setUp();
            _flood(sizes[i]);
            uint256 used = _lockGas();
            console2.log(sizes[i], used);
            if (i == 0) first = used;
            else assertEq(used, first, "the lock's cost must not depend on what is queued against it");
        }
    }
}
