// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

interface IMigrator {
    function setNextVault(address vault, address nextVault) external;

    function nextVault(address vault) external view returns (address);
}
