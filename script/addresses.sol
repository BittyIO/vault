// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

library mainnet {
    address public constant WHITE_LIST = 0x00000000E30003A97Fc8A8A3c293b5f01FB4f525;
    address public constant SUBSCRIPTION = 0x0000000099e7d10b6169A893C037a4c4e237B853;
    /// @dev Gnosis Safe v1.3.0 (GnosisSafeProxyFactory / GnosisSafe L2 singleton)
    address public constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address public constant SAFE_SINGLETON = 0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552;
}

library sepolia {
    address public constant WHITE_LIST = 0x00000000E30003A97Fc8A8A3c293b5f01FB4f525;
    address public constant SUBSCRIPTION = 0x0000000099e7d10b6169A893C037a4c4e237B853;
    address public constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address public constant SAFE_SINGLETON = 0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552;
}
