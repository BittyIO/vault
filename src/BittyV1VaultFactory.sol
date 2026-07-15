// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {AddressZero} from "./interfaces/IBittyV1Vault.sol";
import {IBittyV1Guard, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {BittyV1Vault} from "./BittyV1Vault.sol";
import {IBittyV1VaultFactory, VaultAlreadyDeployed, NotDeployer} from "./interfaces/IBittyV1VaultFactory.sol";

/**
 * @title BittyV1VaultFactory
 * @notice Deploys BittyV1Vault instances with deterministic addresses per (owner, name) pair,
 *         allowing one owner to hold multiple vaults distinguished by name.
 */
contract BittyV1VaultFactory is IBittyV1VaultFactory, Initializable {
    // Only a transaction originated by this address may initialize the factory (set the
    // implementation, guard and weth). tx.origin is used, not msg.sender, because the factory
    // is deployed/initialized through a CREATE2 factory, so msg.sender is that factory, not the
    // deployer EOA. Baked in as a constant so the factory's init code — and therefore its CREATE2
    // address — is identical on every chain, while a squatter cannot set their own guard.
    address public constant DEPLOYER = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    address public guardAddress;
    address public vaultImplementation;
    address public wethAddress;
    address public defiFacetAddress;

    event VaultDeployed(address indexed vault, address indexed owner, string name);

    function initialize(address vaultImplementation_, address defiFacet_, address guardAddress_, address wethAddress_)
        external
        override
        initializer
    {
        if (tx.origin != DEPLOYER) revert NotDeployer();
        if (vaultImplementation_ == address(0)) revert AddressZero();
        if (defiFacet_ == address(0)) revert AddressZero();
        if (guardAddress_ == address(0)) revert AddressZero();
        if (wethAddress_ == address(0)) revert AddressZero();
        vaultImplementation = vaultImplementation_;
        defiFacetAddress = defiFacet_;
        guardAddress = guardAddress_;
        wethAddress = wethAddress_;
    }

    /**
     * @notice Deploy a clean vault owned by the caller (msg.sender).
     * @param name The name of the vault. The vault address is deterministic on (msg.sender, name),
     *             so one owner can hold multiple vaults distinguished by name.
     * @return vault The address of the deployed vault.
     */
    function deployVault(string memory name) external override returns (address vault) {
        return _deployVault(
            msg.sender,
            name,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    /**
     * @notice Deploy a vault owned by the caller (msg.sender), selecting protocols and assets.
     * @param name The name of the vault. The vault address is deterministic on (msg.sender, name).
     * @param assetManagers The addresses of the asset managers (hot wallet / AI agents), can not be the owner.
     * @param assetAddresses Guard-registered assets and/or stable coins to add to the vault.
     * @param lendingProtocols The addresses of the lending protocols, must be registered in guard.
     * @param stakingProtocols The addresses of the staking protocols, must be registered in guard.
     * @param ammProtocols The addresses of the amm protocols, must be registered in guard.
     * @return vault The address of the deployed vault.
     */
    function deployVaultWithSelected(
        string memory name,
        address[] memory assetManagers,
        address[] memory assetAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols
    ) external override returns (address vault) {
        _checkGuard(assetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);

        return _deployVault(
            msg.sender,
            name,
            assetManagers,
            assetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );
    }

    /**
     * @notice Deploy a vault owned by the caller (msg.sender) with all guard assets and protocols.
     * @param name The name of the vault. The vault address is deterministic on (msg.sender, name).
     * @param assetManagers The addresses of the asset managers (hot wallet / AI agents).
     * @return vault The address of the deployed vault.
     */
    function deployVaultAllSelected(string memory name, address[] memory assetManagers)
        external
        override
        returns (address vault)
    {
        IBittyV1Guard guard = IBittyV1Guard(guardAddress);
        address[] memory lendingProtocols = guard.getLendingProtocols();
        address[] memory stakingProtocols = guard.getStakingProtocols();
        address[] memory ammProtocols = guard.getAMMProtocols();
        address[] memory intentProtocols = guard.getIntentProtocols();
        address[] memory assetAddresses = guard.getAssets();
        address[] memory stableCoinAddresses = guard.getStableCoins();
        address[] memory allAssetAddresses = new address[](assetAddresses.length + stableCoinAddresses.length);
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            allAssetAddresses[i] = assetAddresses[i];
        }
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            allAssetAddresses[assetAddresses.length + i] = stableCoinAddresses[i];
        }
        return _deployVault(
            msg.sender,
            name,
            assetManagers,
            allAssetAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );
    }

    function _deployVault(
        address owner,
        string memory name,
        address[] memory assetManagers,
        address[] memory assetAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols
    ) internal returns (address vault) {
        // `owner` is always the caller (msg.sender): the deploy functions derive it and never
        // accept it as input. This makes the vault's owner unforgeable — nobody can pre-deploy
        // someone else's deterministic vault to inject a hostile asset manager or set an
        // unrecoverable owner. msg.sender can never be the zero address, so no owner check is needed.
        bytes32 salt = keccak256(abi.encodePacked(owner, name));
        if (Clones.predictDeterministicAddress(vaultImplementation, salt, address(this)).code.length > 0) {
            revert VaultAlreadyDeployed();
        }

        vault = Clones.cloneDeterministic(vaultImplementation, salt);
        BittyV1Vault(payable(vault))
            .initialize(
                owner,
                name,
                assetManagers,
                guardAddress,
                wethAddress,
                assetAddresses,
                lendingProtocols,
                stakingProtocols,
                ammProtocols,
                intentProtocols,
                defiFacetAddress
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
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols
    ) internal view {
        IBittyV1Guard guard = IBittyV1Guard(guardAddress);
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            address assetAddress = assetAddresses[i];
            if (!guard.isAssetRegistered(assetAddress) && !guard.isStableCoinRegistered(assetAddress)) {
                revert NotRegistered();
            }
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
        for (uint256 i = 0; i < intentProtocols.length; i++) {
            if (!guard.isIntentProtocolRegistered(intentProtocols[i])) revert NotRegistered();
        }
    }
}
