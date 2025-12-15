// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IVersionized} from "../../src/interfaces/IVersionized.sol";

/**
 * @title SimpleMockVault
 * @notice Simplified mock vault for testing Migrator contract
 * @dev This is a minimal implementation that only implements IVersionizedVault
 */
contract SimpleMockVault is IVersionized {
    uint256 public version;
    bytes public args;
    address public previousVault;
    address public migrator;

    constructor(uint256 _version) {
        version = _version;
    }

    function initializeFromPreviousVersion(address previousVersionVaultAddress, bytes memory _args) external override {
        previousVault = previousVersionVaultAddress;
        args = _args;
        version = abi.decode(_args, (uint256));
    }

    function migrateAssets(uint256) external pure override {
        // No-op for simple testing
    }

    function createAndMigrate(uint256, string calldata) external pure override returns (address) {
        return address(0);
    }
}

