// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

interface IMigrator {
    function setVersionizedVault(address _vault, bytes calldata _args, bool _forceUpdate) external;

    function createNextVersionVault(string calldata salt, address _vault) external returns (address);

    function nextVersionVault(address _trustee, address _vault) external view returns (address);
}
