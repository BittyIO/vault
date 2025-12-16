// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {AddressZero, Unauthorized, VaultAlreadyDeployed} from "./interfaces/Errors.sol";
import {IWhiteList} from "./interfaces/IWhiteList.sol";
import {IMigrator} from "./interfaces/IMigrator.sol";
import {BittyVault} from "./BittyVault.sol";
import {FactoryHelper} from "./helpers/FactoryHelper.sol";

/**
 * @title BittyVaultFactory
 * @notice Factory contract for deploying BittyVault instances using CREATE2
 * @dev Each grantor address will generate a unique, deterministic BittyVault address
 */
contract BittyVaultFactory is Initializable {
    IWhiteList public whiteList;
    IMigrator public migrator;
    address public vaultImplementation;
    /**
     * @notice Emitted when a new BittyVault is deployed
     * @param vault The address of the deployed vault
     * @param grantor The grantor address that will own this vault
     * @param inputSalt The salt used for the deployment
     */
    event VaultDeployed(address indexed vault, address indexed grantor, string inputSalt);

    address public wethAddress;

    function initialize(
        address vaultImplementation_,
        address wethAddress_,
        address whiteListAddress_,
        address migratorAddress_
    ) public initializer {
        if (vaultImplementation_ == address(0) || wethAddress_ == address(0)) {
            revert AddressZero();
        }
        vaultImplementation = vaultImplementation_;
        wethAddress = wethAddress_;
        whiteList = IWhiteList(whiteListAddress_);
        migrator = IMigrator(migratorAddress_);
    }

    function deployVault(
        string memory inputSalt,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory yieldProviders,
        address[] memory swapProviders
    ) external returns (address vault) {
        FactoryHelper.checkWhiteList(whiteList, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        bytes32 salt = keccak256(abi.encodePacked(msg.sender, inputSalt));
        address computedAddress = Clones.predictDeterministicAddress(vaultImplementation, salt, address(this));

        if (computedAddress.code.length > 0) revert VaultAlreadyDeployed();

        vault = Clones.cloneDeterministic(vaultImplementation, salt);

        BittyVault(payable(vault))
            .initialize(
                msg.sender,
                wethAddress,
                address(whiteList),
                address(migrator),
                assetAddresses,
                stableCoinAddresses,
                yieldProviders,
                swapProviders
            );

        emit VaultDeployed(vault, msg.sender, inputSalt);
    }

    function computeVaultAddress(address grantor, string memory inputSalt) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(grantor, inputSalt));
        return Clones.predictDeterministicAddress(vaultImplementation, salt, address(this));
    }
}

