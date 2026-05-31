// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {AddressZero} from "./interfaces/IVault.sol";
import {IWhiteList, NotWhiteListed} from "whitelist-contracts/src/interfaces/IWhiteList.sol";
import {Vault} from "./Vault.sol";
import {IFactory, VaultAlreadyDeployed} from "./interfaces/IFactory.sol";

/**
 * @title Factory
 * @notice Deploys Vault instances with deterministic addresses per owner.
 */
contract Factory is IFactory, Initializable {
    address public whiteListAddress;
    address public vaultImplementation;
    address public wethAddress;

    event VaultDeployed(address indexed vault, address indexed owner);

    function initialize(address vaultImplementation_, address whiteListAddress_, address wethAddress_)
        external
        override
        initializer
    {
        if (vaultImplementation_ == address(0)) revert AddressZero();
        if (whiteListAddress_ == address(0)) revert AddressZero();
        if (wethAddress_ == address(0)) revert AddressZero();
        vaultImplementation = vaultImplementation_;
        whiteListAddress = whiteListAddress_;
        wethAddress = wethAddress_;
    }

    function deployVault(
        address owner,
        address assetManager,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory ammProviders
    ) external override returns (address vault) {
        if (owner == address(0)) revert AddressZero();
        _checkWhiteList(assetAddresses, stableCoinAddresses, lendingProviders, stakingProviders, ammProviders);

        bytes32 salt = keccak256(abi.encodePacked(owner));
        if (Clones.predictDeterministicAddress(vaultImplementation, salt, address(this)).code.length > 0) {
            revert VaultAlreadyDeployed();
        }

        vault = Clones.cloneDeterministic(vaultImplementation, salt);
        _initVault(
            vault,
            owner,
            assetManager,
            assetAddresses,
            stableCoinAddresses,
            lendingProviders,
            stakingProviders,
            ammProviders
        );

        emit VaultDeployed(vault, owner);
    }

    function computeVaultAddress(address owner) external view override returns (address) {
        return
            Clones.predictDeterministicAddress(vaultImplementation, keccak256(abi.encodePacked(owner)), address(this));
    }

    function _initVault(
        address vault,
        address owner_,
        address assetManager,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory ammProviders
    ) internal {
        Vault(payable(vault))
            .initialize(
                owner_,
                assetManager,
                whiteListAddress,
                wethAddress,
                assetAddresses,
                stableCoinAddresses,
                lendingProviders,
                stakingProviders,
                ammProviders
            );
    }

    function _checkWhiteList(
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory ammProviders
    ) internal view {
        IWhiteList whiteList = IWhiteList(whiteListAddress);
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (!whiteList.isAssetWhiteListed(assetAddresses[i])) revert NotWhiteListed();
        }
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (!whiteList.isStableCoinWhiteListed(stableCoinAddresses[i])) revert NotWhiteListed();
        }
        for (uint256 i = 0; i < lendingProviders.length; i++) {
            if (!whiteList.isLendingProviderWhiteListed(lendingProviders[i])) revert NotWhiteListed();
        }
        for (uint256 i = 0; i < stakingProviders.length; i++) {
            if (!whiteList.isStakingProviderWhiteListed(stakingProviders[i])) revert NotWhiteListed();
        }
        for (uint256 i = 0; i < ammProviders.length; i++) {
            if (!whiteList.isAMMProviderWhiteListed(ammProviders[i])) revert NotWhiteListed();
        }
    }
}
