// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {AddressZero} from "./interfaces/IVault.sol";
import {IGuard, NotRegistered} from "guard-contracts/src/interfaces/IGuard.sol";
import {BittyVault} from "./BittyVault.sol";
import {IVaultFactory, VaultAlreadyDeployed} from "./interfaces/IVaultFactory.sol";

/**
 * @title BittyVaultFactory
 * @notice Deploys BittyVault instances with deterministic addresses per (owner, name) pair,
 *         allowing one owner to hold multiple vaults distinguished by name.
 */
contract BittyVaultFactory is IVaultFactory, Initializable {
    address public guardAddress;
    address public vaultImplementation;
    address public wethAddress;

    event VaultDeployed(address indexed vault, address indexed owner, string name);

    function initialize(address vaultImplementation_, address guardAddress_, address wethAddress_)
        external
        override
        initializer
    {
        if (vaultImplementation_ == address(0)) revert AddressZero();
        if (guardAddress_ == address(0)) revert AddressZero();
        if (wethAddress_ == address(0)) revert AddressZero();
        vaultImplementation = vaultImplementation_;
        guardAddress = guardAddress_;
        wethAddress = wethAddress_;
    }

    /**
     * @notice Deploy a clean vault owned by owner with name.
     * @param owner The address of the owner.
     * @param name The name of the vault, can not be address(0), better be a safe multi-sig address.
     * @return vault The address of the deployed vault.
     */
    function deployVault(address owner, string memory name) external override returns (address vault) {
        return _deployVault(
            owner,
            name,
            address(0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    /**
     * @notice Deploy a vault owned by owner with name and make the asset manager start to work.
     * @param owner The address of the owner.
     * @param name The name of the vault, can not be address(0), better be a safe multi-sig address.
     * @param assetManager The address of the asset manager (hot wallet / AI agent), can not be the owner.
     * @param assetAddresses The addresses of the assets.
     * @param stableCoinAddresses The addresses of the stable coins.
     * @param lendingProtocols The addresses of the lending protocols, must be registered in guard.
     * @param stakingProtocols The addresses of the staking protocols, must be registered in guard.
     * @param ammProtocols The addresses of the amm protocols, must be registered in guard.
     * @return vault The address of the deployed vault.
     */
    function deployVault(
        address owner,
        string memory name,
        address assetManager,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols
    ) external override returns (address vault) {
        _checkGuard(assetAddresses, stableCoinAddresses, lendingProtocols, stakingProtocols, ammProtocols);

        return _deployVault(
            owner,
            name,
            assetManager,
            assetAddresses,
            stableCoinAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols
        );
    }

    function _deployVault(
        address owner,
        string memory name,
        address assetManager,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols
    ) internal returns (address vault) {
        if (owner == address(0)) revert AddressZero();

        bytes32 salt = keccak256(abi.encodePacked(owner, name));
        if (Clones.predictDeterministicAddress(vaultImplementation, salt, address(this)).code.length > 0) {
            revert VaultAlreadyDeployed();
        }

        vault = Clones.cloneDeterministic(vaultImplementation, salt);
        BittyVault(payable(vault))
            .initialize(
                owner,
                name,
                assetManager,
                guardAddress,
                wethAddress,
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

    function _checkGuard(
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols
    ) internal view {
        IGuard guard = IGuard(guardAddress);
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (!guard.isAssetRegistered(assetAddresses[i])) revert NotRegistered();
        }
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (!guard.isStableCoinRegistered(stableCoinAddresses[i])) revert NotRegistered();
        }
        for (uint256 i = 0; i < lendingProtocols.length; i++) {
            if (!guard.isLendingProtocolRegistered(lendingProtocols[i])) revert NotRegistered();
        }
        for (uint256 i = 0; i < stakingProtocols.length; i++) {
            if (!guard.isStakingProtocolRegistered(stakingProtocols[i])) revert NotRegistered();
        }
        for (uint256 i = 0; i < ammProtocols.length; i++) {
            if (!guard.isAMMProtocolRegistered(ammProtocols[i])) revert NotRegistered();
        }
    }
}
