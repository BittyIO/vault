// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/// @notice Minimal Safe stand-in for unit tests. Vault owner is `address(this)`.
/// @dev `exec` is owner-gated and bubbles vault reverts (like a failed inner call on a real Safe tx).
contract MockSafe {
    address[] internal _owners;
    uint256 internal _threshold;

    function setup(
        address[] calldata owners,
        uint256 threshold,
        address,
        bytes calldata,
        address,
        address,
        uint256,
        address payable
    ) external {
        _owners = owners;
        _threshold = threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    /// @dev Forward a call so `msg.sender` is this contract (the vault owner).
    function exec(address target, bytes calldata data) external {
        require(_isOwner(msg.sender), "MockSafe: not owner");
        (bool success, bytes memory returnData) = target.call(data);
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    function _isOwner(address account) internal view returns (bool) {
        for (uint256 i = 0; i < _owners.length; i++) {
            if (_owners[i] == account) {
                return true;
            }
        }
        return false;
    }
}
