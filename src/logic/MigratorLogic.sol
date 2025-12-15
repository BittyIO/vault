// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {AddressZero, AlreadyInitialized, NotInitialized} from "../interfaces/Errors.sol";
import {IMigrator} from "../interfaces/IMigrator.sol";
import {MigratorStorage} from "./Storages.sol";

library MigratorLogic {
    modifier onlyNotInitialized(MigratorStorage storage logicStorage) {
        _onlyNotInitialized(logicStorage);
        _;
    }

    function _onlyNotInitialized(MigratorStorage storage logicStorage) private view {
        if (logicStorage.isInitialized) {
            revert AlreadyInitialized();
        }
    }

    modifier onlyInitialized(MigratorStorage storage logicStorage) {
        _onlyInitialized(logicStorage);
        _;
    }

    function _onlyInitialized(MigratorStorage storage logicStorage) private view {
        if (!logicStorage.isInitialized) {
            revert NotInitialized();
        }
    }

    function initialize(MigratorStorage storage logicStorage, address migratorAddress)
        external
        onlyNotInitialized(logicStorage)
    {
        if (migratorAddress == address(0)) {
            revert AddressZero();
        }
        logicStorage.migrator = migratorAddress;
        logicStorage.isInitialized = true;
    }

    function create(MigratorStorage storage logicStorage, uint256 _toVersion, string calldata _salt)
        external
        onlyInitialized(logicStorage)
        returns (address)
    {
        address nextVault = IMigrator(logicStorage.migrator).createVersionVault(address(this), _toVersion, _salt);
        if (nextVault == address(0)) {
            revert AddressZero();
        }
        return nextVault;
    }

    function versionVault(MigratorStorage storage logicStorage, address _fromVault, uint256 _toVersion)
        external
        view
        returns (address)
    {
        return IMigrator(logicStorage.migrator).versionVault(_fromVault, _toVersion);
    }
}
