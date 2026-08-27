// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";

interface IProtocolMembership {
    function isProtocolAllowed(address protocol) external view returns (bool);
}

/**
 * @dev Rebuilds a vault's protocol list for tests.
 *
 * The vault stores membership as a flag now and no longer enumerates - ProtocolsUpdated carries the
 * changes, and production consumers replay that. Tests want the set itself, and can get it without a
 * per-file fixture list: a vault can only ever list protocols the guard registered, so filtering the
 * guard's two lists through the vault's own membership check reproduces it exactly.
 */
function vaultProtocols(address guard, address vault) view returns (address[] memory listed) {
    address[] memory active = IBittyV1Guard(guard).getProtocols();
    address[] memory deprecated = IBittyV1Guard(guard).getDeprecatedProtocols();
    address[] memory buf = new address[](active.length + deprecated.length);
    uint256 n;
    for (uint256 i = 0; i < active.length; i++) {
        if (IProtocolMembership(vault).isProtocolAllowed(active[i])) buf[n++] = active[i];
    }
    for (uint256 i = 0; i < deprecated.length; i++) {
        if (IProtocolMembership(vault).isProtocolAllowed(deprecated[i])) buf[n++] = deprecated[i];
    }
    listed = new address[](n);
    for (uint256 i = 0; i < n; i++) {
        listed[i] = buf[i];
    }
}
