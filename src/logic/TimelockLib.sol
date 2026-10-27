// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {TimelockedValue} from "./BittyStorage.sol";
import {ALLOWANCE_ZERO} from "./Constants.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

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

    /**
     * Drop a waiting loosening; one whose time has already come is in force, so it stays.
     */
    function cancelPending(TimelockedValue storage tv) internal {
        if (tv.pendingAt == 0) return;
        _settle(tv);
        tv.pending = 0;
        tv.pendingAt = 0;
    }

    function _apply(TimelockedValue storage tv, uint64 next, bool loosen, uint64 timelock) private {
        if (!loosen) {
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
        uint64 n = SafeCast.toUint64(next);
        _apply(tv, n, n < tv.value, timelock);
    }

    function setCap(TimelockedValue storage tv, uint256 next, uint64 timelock) internal {
        _settle(tv);
        uint64 n = SafeCast.toUint64(next);
        _apply(tv, n, _capRank(n) > _capRank(tv.value), timelock);
    }

    /**
     * A cap ordered by how loose it is: unset (0) is the loosest, {ALLOWANCE_ZERO} the tightest.
     */
    function _capRank(uint64 v) private pure returns (uint256) {
        if (v == 0) return type(uint256).max;
        if (v == ALLOWANCE_ZERO) return 0;
        return v;
    }

    function setGasBudget(TimelockedValue storage tv, uint64 next, uint64 timelock) internal {
        _settle(tv);
        bool loosen = next == 0 || (tv.value != 0 && next > tv.value);
        _apply(tv, next, loosen, timelock);
    }
}
