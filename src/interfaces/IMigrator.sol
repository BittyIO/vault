// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

interface IMigrator {
    function setVersionizedVault(address _vault, bytes calldata _args, bool _forceUpdate) external;

    function createVersionVault(address _fromVault, uint256 _toVersion, string calldata salt) external returns (address);

    function versionVault(address _fromVault, uint256 _toVersion) external view returns (address);
}
