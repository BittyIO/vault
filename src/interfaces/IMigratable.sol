// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

interface IMigratable {
    function migrator() external view returns (address);

    function migrate() external;
}
