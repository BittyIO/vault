// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {AddressZero} from "./interfaces/IVault.sol";
import {IWhiteList, NotWhiteListed} from "whitelist-contracts/src/interfaces/IWhiteList.sol";
import {Vault} from "./Vault.sol";
import {IFactory, VaultAlreadyDeployed, InvalidThreshold, OwnersRequired} from "./interfaces/IFactory.sol";
import {GnosisSafe} from "safe-smart-account/contracts/GnosisSafe.sol";
import {GnosisSafeProxyFactory} from "safe-smart-account/contracts/proxies/GnosisSafeProxyFactory.sol";

/**
 * @title Factory
 * @notice Deploys Vault instances. Supports single-EOA ownership and Gnosis Safe multi-sig ownership.
 */
contract Factory is IFactory, Initializable {
    address public whiteListAddress;
    address public subscriptionAddress;
    address public vaultImplementation;
    address public wethAddress;
    address public safeProxyFactory;
    address public safeSingleton;

    event VaultDeployed(address indexed vault, address indexed owner);
    event VaultDeployedMultiSig(address indexed vault, address indexed safe, uint256 threshold, uint256 ownerCount);

    function initialize(
        address vaultImplementation_,
        address whiteListAddress_,
        address subscriptionAddress_,
        address wethAddress_,
        address safeProxyFactory_,
        address safeSingleton_
    ) external override initializer {
        if (vaultImplementation_ == address(0)) revert AddressZero();
        if (whiteListAddress_ == address(0)) revert AddressZero();
        if (subscriptionAddress_ == address(0)) revert AddressZero();
        if (wethAddress_ == address(0)) revert AddressZero();
        if (safeProxyFactory_ == address(0)) revert AddressZero();
        if (safeSingleton_ == address(0)) revert AddressZero();
        vaultImplementation = vaultImplementation_;
        whiteListAddress = whiteListAddress_;
        subscriptionAddress = subscriptionAddress_;
        wethAddress = wethAddress_;
        safeProxyFactory = safeProxyFactory_;
        safeSingleton = safeSingleton_;
    }

    /// @inheritdoc IFactory
    function deployVault(
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory ammProviders
    ) external override returns (address vault) {
        _checkWhiteList(assetAddresses, stableCoinAddresses, lendingProviders, stakingProviders, ammProviders);

        bytes32 salt = keccak256(abi.encodePacked(msg.sender));
        if (Clones.predictDeterministicAddress(vaultImplementation, salt, address(this)).code.length > 0) {
            revert VaultAlreadyDeployed();
        }

        vault = Clones.cloneDeterministic(vaultImplementation, salt);
        _initVault(
            vault, tx.origin, assetAddresses, stableCoinAddresses, lendingProviders, stakingProviders, ammProviders
        );

        emit VaultDeployed(vault, tx.origin);
    }

    /// @inheritdoc IFactory
    function deployVaultMultiSig(
        address[] memory owners,
        uint256 threshold,
        uint256 saltNonce,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory ammProviders
    ) external override returns (address safe, address vault) {
        if (owners.length == 0) revert OwnersRequired();
        if (threshold == 0 || threshold > owners.length) revert InvalidThreshold();
        _checkWhiteList(assetAddresses, stableCoinAddresses, lendingProviders, stakingProviders, ammProviders);

        bytes memory setupCalldata = abi.encodeCall(
            GnosisSafe.setup, (owners, threshold, address(0), "", address(0), address(0), 0, payable(address(0)))
        );
        safe = address(
            GnosisSafeProxyFactory(safeProxyFactory).createProxyWithNonce(safeSingleton, setupCalldata, saltNonce)
        );

        bytes32 salt = keccak256(abi.encodePacked(safe));
        if (Clones.predictDeterministicAddress(vaultImplementation, salt, address(this)).code.length > 0) {
            revert VaultAlreadyDeployed();
        }

        vault = Clones.cloneDeterministic(vaultImplementation, salt);
        _initVault(vault, safe, assetAddresses, stableCoinAddresses, lendingProviders, stakingProviders, ammProviders);

        emit VaultDeployedMultiSig(vault, safe, threshold, owners.length);
    }

    /// @inheritdoc IFactory
    function computeVaultAddress(address owner) external view override returns (address) {
        return
            Clones.predictDeterministicAddress(vaultImplementation, keccak256(abi.encodePacked(owner)), address(this));
    }

    /// @inheritdoc IFactory
    function computeVaultAddressMultiSig(address safe) external view override returns (address) {
        return Clones.predictDeterministicAddress(vaultImplementation, keccak256(abi.encodePacked(safe)), address(this));
    }

    function _initVault(
        address vault,
        address owner_,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory ammProviders
    ) internal {
        Vault(payable(vault))
            .initialize(
                owner_,
                whiteListAddress,
                subscriptionAddress,
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
