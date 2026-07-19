// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AddressZero, RiskControlLevel} from "./interfaces/IBittyV1Vault.sol";
import {IBittyV1Guard, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {BittyV1Vault} from "./BittyV1Vault.sol";
import {
    IBittyV1VaultFactory,
    VaultAlreadyActivated,
    NotDeployer,
    EthTransferFailed
} from "./interfaces/IBittyV1VaultFactory.sol";

/**
 * @title BittyV1VaultFactory
 * @notice Activates BittyV1Vault instances at an address deterministic on the owner alone,
 *         so each address has exactly one vault.
 */
contract BittyV1VaultFactory is IBittyV1VaultFactory, Initializable {
    using SafeERC20 for IERC20;

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

    event VaultActivated(address indexed owner);

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
     * @inheritdoc IBittyV1VaultFactory
     */
    function activateVault(
        RiskControlLevel riskLevel,
        address[] memory assetAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols
    ) external override {
        _checkGuard(assetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);
        _activate(riskLevel, assetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);
    }

    /**
     * @inheritdoc IBittyV1VaultFactory
     */
    function activateVaultWithAssets(
        RiskControlLevel riskLevel,
        address[] memory assetAddresses,
        AssetInput[] memory deposits,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols
    ) external payable override {
        _checkGuard(assetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);

        address vault =
            _activate(riskLevel, assetAddresses, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols);

        for (uint256 i = 0; i < deposits.length; i++) {
            AssetInput memory d = deposits[i];
            if (d.usePermit) {
                try IERC20Permit(d.asset).permit(msg.sender, address(this), d.amount, d.deadline, d.v, d.r, d.s) {}
                    catch {}
            }
            IERC20(d.asset).safeTransferFrom(msg.sender, vault, d.amount);
        }

        if (msg.value > 0) {
            (bool ok,) = payable(vault).call{value: msg.value}("");
            if (!ok) revert EthTransferFailed();
        }
    }

    function _activate(
        RiskControlLevel riskLevel,
        address[] memory assetAddresses,
        address[] memory lendingProtocols,
        address[] memory stakingProtocols,
        address[] memory ammProtocols,
        address[] memory intentProtocols
    ) internal returns (address vault) {
        bytes32 salt = keccak256(abi.encodePacked(msg.sender));
        if (Clones.predictDeterministicAddress(vaultImplementation, salt, address(this)).code.length > 0) {
            revert VaultAlreadyActivated();
        }

        vault = Clones.cloneDeterministic(vaultImplementation, salt);
        BittyV1Vault(payable(vault))
            .initialize(
                msg.sender,
                guardAddress,
                wethAddress,
                assetAddresses,
                lendingProtocols,
                stakingProtocols,
                ammProtocols,
                intentProtocols,
                defiFacetAddress,
                riskLevel
            );

        emit VaultActivated(msg.sender);
    }

    function vaultAddress(address owner) external view override returns (address vault) {
        return
            Clones.predictDeterministicAddress(vaultImplementation, keccak256(abi.encodePacked(owner)), address(this));
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
