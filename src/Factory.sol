// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {AddressZero} from "./interfaces/IVault.sol";
import {IWhiteList, NotWhiteListed} from "whitelist-contracts/src/interfaces/IWhiteList.sol";
import {Vault} from "./Vault.sol";
import {IFactory, VaultAlreadyDeployed} from "./interfaces/IFactory.sol";

/**
 * @title Factory
 * @notice Factory contract for deploying Vault instances using CREATE2
 * @dev Each owner address will generate a unique, deterministic Vault address
 */
contract Factory is IFactory, Initializable {
    IWhiteList public whiteList;
    address public vaultImplementation;
    address public wethAddress;
    /**
     * @notice Emitted when a new Vault is deployed
     * @param vault The address of the deployed vault
     * @param owner The owner address that will own this vault
     */
    event VaultDeployed(address indexed vault, address indexed owner);

    function initialize(address vaultImplementation_, address whiteListAddress_, address wethAddress_)
        external
        override
        initializer
    {
        if (vaultImplementation_ == address(0)) {
            revert AddressZero();
        }
        vaultImplementation = vaultImplementation_;
        if (whiteListAddress_ == address(0)) {
            revert AddressZero();
        }
        whiteList = IWhiteList(whiteListAddress_);
        if (wethAddress_ == address(0)) {
            revert AddressZero();
        }
        wethAddress = wethAddress_;
    }

    function deployVault(
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory swapProviders
    ) external override returns (address vault) {
        _checkWhiteList(assetAddresses, stableCoinAddresses, lendingProviders, stakingProviders, swapProviders);

        bytes32 salt = keccak256(abi.encodePacked(msg.sender));
        address computedAddress = Clones.predictDeterministicAddress(vaultImplementation, salt, address(this));

        if (computedAddress.code.length > 0) revert VaultAlreadyDeployed();

        vault = Clones.cloneDeterministic(vaultImplementation, salt);

        Vault(payable(vault))
            .initialize(
                address(whiteList),
                wethAddress,
                assetAddresses,
                stableCoinAddresses,
                lendingProviders,
                stakingProviders,
                swapProviders
            );

        emit VaultDeployed(vault, msg.sender);
    }

    function computeVaultAddress(address owner) external view override returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(owner));
        return Clones.predictDeterministicAddress(vaultImplementation, salt, address(this));
    }

    /**
     * @notice Check if all addresses are whitelisted
     * @dev Validates assets, stablecoins, yield providers, and swap providers
     */
    function _checkWhiteList(
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory swapProviders
    ) internal view {
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
        for (uint256 i = 0; i < swapProviders.length; i++) {
            if (!whiteList.isAMMProviderWhiteListed(swapProviders[i])) revert NotWhiteListed();
        }
    }
}

