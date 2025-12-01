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
    error InvalidVersion();

    struct VaultWithArgs {
        address vault;
        bytes args;
    }
    mapping(uint256 => VaultWithArgs) public versionToVault;
    mapping(address => uint256) public vaultToVersion;

    // fromVault => nextVersionVault
    mapping(address => address) public nextVersionVaults;

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

    function createVersionVault(address _fromVault, uint256 _toVersion, string calldata salt)
        external
        override
        returns (address)
    {
        IVersionizedVault _vault = IVersionizedVault(_fromVault);
        uint256 fromVersion = _vault.version();
        if (fromVersion >= _toVersion) {
            revert InvalidVersion();
        }
        uint256 _nextVersion = fromVersion;
        do {
            _nextVersion++;
            _vault = IVersionizedVault(_createNextVersionVault(address(_vault), _nextVersion, salt));
        } while (_vault.version() < _toVersion);
        return address(_vault);
    }

    function _createNextVersionVault(address _fromVault, uint256 _nextVersion, string calldata salt)
        private
        returns (address)
    {
        // Check if next vault already exists for this vault
        address nextVault = nextVersionVaults[_fromVault];
        if (nextVault != address(0)) {
            return nextVault;
        }
        VaultWithArgs memory nextVaultWithArgs = versionToVault[_nextVersion];
        if (nextVaultWithArgs.vault == address(0)) {
            revert NoNextVersionVault();
        }
        bytes32 saltHash = keccak256(abi.encodePacked(_fromVault, salt));
        // Calculate the deterministic address first
        nextVault = Clones.predictDeterministicAddress(nextVaultWithArgs.vault, saltHash);
        // MEV attack protection: if vault is already deployed, revert
        if (nextVault.code.length > 0) {
            revert VaultAlreadyDeployed();
        }
        // Clone and initialize
        nextVault = Clones.cloneDeterministic(nextVaultWithArgs.vault, saltHash);
        IVersionizedVault(nextVault).initialize(_fromVault, nextVaultWithArgs.args);
        if (IVersionizedVault(nextVault).version() != _nextVersion) {
            revert VersionMismatch();
        }
        nextVersionVaults[_fromVault] = nextVault;
        return nextVault;
    }

    function _nextVersionVault(address _fromVault) private view returns (address) {
        address nextVault = nextVersionVaults[_fromVault];
        if (nextVault == address(0)) {
            revert NoNextVersionVault();
        }
        return nextVault;
    }

    function versionVault(address _fromVault, uint256 _toVersion) external view override returns (address) {
        IVersionizedVault _vault = IVersionizedVault(_fromVault);
        if (_vault.version() >= _toVersion) {
            revert InvalidVersion();
        }
        do {
            _vault = IVersionizedVault(_nextVersionVault(address(_vault)));
        } while (_vault.version() < _toVersion);
        return address(_vault);
    }
}
