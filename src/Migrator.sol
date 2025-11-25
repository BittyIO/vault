// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IMigrator} from "./interfaces/IMigrator.sol";
import {IVersionizedVault} from "./interfaces/IVersionizedVault.sol";

contract Migrator is IMigrator, Ownable {
    error VaultAlreadyVersioned();
    error NoNextVersionVault();
    error VersionAlreadyUsed();
    error VersionMismatch();
    error VaultAlreadyDeployed();

    struct VaultWithArgs {
        address vault;
        bytes args;
    }
    mapping(uint256 => VaultWithArgs) public versionToVault;
    mapping(address => uint256) public vaultToVersion;
    mapping(address => mapping(address => address)) public nextVersionVaults;

    function setVersionizedVault(address _vault, bytes calldata _args, bool _forceUpdate) external override onlyOwner {
        uint256 version = IVersionizedVault(_vault).version();
        if (!_forceUpdate) {
            if (vaultToVersion[_vault] != 0) {
                revert VaultAlreadyVersioned();
            }
            if (versionToVault[version].vault != address(0)) revert VersionAlreadyUsed();
        }
        vaultToVersion[_vault] = version;
        versionToVault[version] = VaultWithArgs({vault: _vault, args: _args});
    }

    function createNextVersionVault(string calldata salt, address _vault) external override returns (address) {
        // Check if next vault already exists for this trustee and vault
        address nextVault = nextVersionVaults[msg.sender][_vault];
        if (nextVault != address(0)) {
            return nextVault;
        }
        uint256 version = vaultToVersion[_vault];
        if (version == 0) {
            revert NoNextVersionVault();
        }
        VaultWithArgs memory nextVaultWithArgs = versionToVault[version + 1];
        if (nextVaultWithArgs.vault == address(0)) {
            revert NoNextVersionVault();
        }
        bytes32 saltHash = keccak256(abi.encodePacked(msg.sender, salt));
        // Calculate the deterministic address first
        nextVault = Clones.predictDeterministicAddress(nextVaultWithArgs.vault, saltHash);
        // MEV attack protection: if vault is already deployed, revert
        if (nextVault.code.length > 0) {
            revert VaultAlreadyDeployed();
        }
        // Clone and initialize
        nextVault = Clones.cloneDeterministic(nextVaultWithArgs.vault, saltHash);
        IVersionizedVault(nextVault).initialize(address(_vault), nextVaultWithArgs.args);
        nextVersionVaults[msg.sender][_vault] = nextVault;
        return nextVault;
    }

    function nextVersionVault(address _trustee, address _vault) external view override returns (address) {
        address nextVault = nextVersionVaults[_trustee][_vault];
        if (nextVault == address(0)) {
            revert NoNextVersionVault();
        }
        return nextVault;
    }
}
