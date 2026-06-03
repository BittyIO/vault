// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {AddressZero} from "./interfaces/IVault.sol";
import {IRegistry, NotRegistered} from "registry-contracts/src/interfaces/IRegistry.sol";
import {Vault} from "./Vault.sol";
import {IVaultFactory, VaultAlreadyDeployed} from "./interfaces/IVaultFactory.sol";

/**
 * @title BittyVaultFactory
 * @notice Deploys Vault instances with deterministic addresses per (owner, name) pair,
 *         allowing one owner to hold multiple vaults distinguished by name.
 */
contract BittyVaultFactory is IVaultFactory, Initializable {
    address public registryAddress;
    address public vaultImplementation;
    address public wethAddress;

    event VaultDeployed(address indexed vault, address indexed owner, string name);

    function initialize(address vaultImplementation_, address registryAddress_, address wethAddress_)
        external
        override
        initializer
    {
        if (vaultImplementation_ == address(0)) revert AddressZero();
        if (registryAddress_ == address(0)) revert AddressZero();
        if (wethAddress_ == address(0)) revert AddressZero();
        vaultImplementation = vaultImplementation_;
        registryAddress = registryAddress_;
        wethAddress = wethAddress_;
    }

    function deployVault(
        address owner,
        string memory name,
        address assetManager,
        address configManager,
        address receiverManager,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols
    ) external override returns (address vault) {
        if (owner == address(0) || configManager == address(0)) revert AddressZero();
        _checkRegistry(assetAddresses, stableCoinAddresses, lendingProtocols, stakingProtocols, ammProtocols);

        bytes32 salt = keccak256(abi.encodePacked(owner, name));
        if (Clones.predictDeterministicAddress(vaultImplementation, salt, address(this)).code.length > 0) {
            revert VaultAlreadyDeployed();
        }

        vault = Clones.cloneDeterministic(vaultImplementation, salt);
        _initVault(
            vault,
            owner,
            name,
            assetManager,
            configManager,
            receiverManager,
            assetAddresses,
            stableCoinAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols
        );

        emit VaultDeployed(vault, owner, name);
    }

    function computeVaultAddress(address owner, string memory name) external view override returns (address) {
        return Clones.predictDeterministicAddress(
            vaultImplementation, keccak256(abi.encodePacked(owner, name)), address(this)
        );
    }

    function _initVault(
        address vault,
        address owner_,
        string memory name,
        address assetManager,
        address configManager,
        address receiverManager,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols
    ) internal {
        Vault(payable(vault))
            .initialize(
                owner_,
                name,
                assetManager,
                configManager,
                receiverManager,
                registryAddress,
                wethAddress,
                assetAddresses,
                stableCoinAddresses,
                lendingProtocols,
                stakingProtocols,
                ammProtocols
            );
    }

    function _checkRegistry(
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols
    ) internal view {
        IRegistry registry = IRegistry(registryAddress);
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (!registry.isAssetRegistered(assetAddresses[i])) revert NotRegistered();
        }
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (!registry.isStableCoinRegistered(stableCoinAddresses[i])) revert NotRegistered();
        }
        for (uint256 i = 0; i < lendingProtocols.length; i++) {
            if (!registry.isLendingProtocolRegistered(lendingProtocols[i])) revert NotRegistered();
        }
        for (uint256 i = 0; i < stakingProtocols.length; i++) {
            if (!registry.isStakingProtocolRegistered(stakingProtocols[i])) revert NotRegistered();
        }
        for (uint256 i = 0; i < ammProtocols.length; i++) {
            if (!registry.isAMMProtocolRegistered(ammProtocols[i])) revert NotRegistered();
        }
    }
}
