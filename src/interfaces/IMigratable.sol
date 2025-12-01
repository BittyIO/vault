// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

interface IMigratable {
    function migrator() external view returns (address);
    function createAndMigrate(uint256 toVersion, string calldata salt) external returns (address);
    function migrateAssets(uint256 toVersion) external;
}
