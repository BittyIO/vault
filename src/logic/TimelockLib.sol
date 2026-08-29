// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {TimelockedValue} from "./BittyStorage.sol";

/**
 * @title TimelockLib
 * @notice The shared timelocked-value math used by the risk config and the relayed-gas budget. A change
 *         that tightens risk (or lowers a limit) applies immediately; a change that loosens is deferred
 *         by the given timelock. Internal, so it inlines into each consumer — no separate deployment.
 */
library TimelockLib {
    function effective(TimelockedValue storage tv) internal view returns (uint64) {
        if (tv.pendingAt != 0 && block.timestamp >= tv.pendingAt) return tv.pending;
        return tv.value;
    }

    function _settle(TimelockedValue storage tv) private {
        if (tv.pendingAt != 0 && block.timestamp >= tv.pendingAt) {
            tv.value = tv.pending;
            tv.pending = 0;
            tv.pendingAt = 0;
        }
    }

    function _apply(TimelockedValue storage tv, uint64 next, bool loosen, uint64 timelock) private {
        if (!loosen || timelock == 0) {
            tv.value = next;
            tv.pending = 0;
            tv.pendingAt = 0;
        } else {
            tv.pending = next;
            tv.pendingAt = uint64(block.timestamp) + timelock;
        }
    }

    function setHigherSafer(TimelockedValue storage tv, uint256 next, uint64 timelock) internal {
        _settle(tv);
        uint64 n = uint64(next);
        _apply(tv, n, n < tv.value, timelock);
    }

    function setCap(TimelockedValue storage tv, uint256 next, uint64 timelock) internal {
        _settle(tv);
        uint64 n = uint64(next);
        bool loosen = tv.value != 0 && (n == 0 || n > tv.value);
        _apply(tv, n, loosen, timelock);
    }

    function setGasBudget(TimelockedValue storage tv, uint64 next, uint64 timelock) internal {
        _settle(tv);
        bool loosen = next == 0 || (tv.value != 0 && next > tv.value);
        _apply(tv, next, loosen, timelock);
    }
}
