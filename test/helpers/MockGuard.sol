// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @notice A configurable stand-in for the Bitty guard, covering the subset the subaccount system reads:
 *         the timelocked implementation registry plus the asset/protocol registries. Etch it at
 *         BITTY_GUARD and drive it with the setters. Public mappings auto-generate the interface getters.
 */
contract MockGuard {
    // Keyed by category, like the guard: the two are separate registries so a sub vault cannot be
    // pointed at main-vault code.
    mapping(uint8 => mapping(address => bool)) internal _registered;

    function isImplementationRegisteredFor(address impl, uint8 category) external view returns (bool) {
        return _registered[category][impl];
    }
    mapping(address => uint8) public assetCategory;
    mapping(address => uint8) public protocolCategory;
    mapping(address => bool) public isProtocolDeprecated;
    address[] internal _protocols;
    address[] internal _deprecated;

    function isAssetRegistered(address a) external view returns (bool) {
        return assetCategory[a] != 0;
    }

    function isProtocolRegistered(address p) external view returns (bool) {
        return protocolCategory[p] != 0;
    }

    function getProtocols() external view returns (address[] memory) {
        return _protocols;
    }

    function getDeprecatedProtocols() external view returns (address[] memory) {
        return _deprecated;
    }

    // ── setters ──
    function setImpl(address impl, bool ok) external {
        // Default to the main-vault category, which is what almost every test means.
        _registered[1][impl] = ok;
    }

    function setImplFor(address impl, uint8 category, bool ok) external {
        _registered[category][impl] = ok;
    }

    function setAsset(address a, uint8 cat) external {
        assetCategory[a] = cat;
    }

    function setProtocol(address p, uint8 cat) external {
        protocolCategory[p] = cat;
        _protocols.push(p);
    }

    function setDeprecated(address p, bool ok) external {
        if (isProtocolDeprecated[p] == ok) return;
        isProtocolDeprecated[p] = ok;
        if (ok) {
            _deprecated.push(p);
            return;
        }
        for (uint256 i; i < _deprecated.length; ++i) {
            if (_deprecated[i] != p) continue;
            _deprecated[i] = _deprecated[_deprecated.length - 1];
            _deprecated.pop();
            return;
        }
    }
}
