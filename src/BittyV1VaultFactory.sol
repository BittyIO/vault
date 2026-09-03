// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "openzeppelin-contracts/contracts/utils/Create2.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {AddressZero} from "./interfaces/IBittyV1Vault.sol";
import {NotDeployer, VaultAlreadyActivated, InvalidActivationSignature} from "./interfaces/IBittyV1VaultFactory.sol";
import {BittyV1Vault} from "./BittyV1Vault.sol";
import {BittyV1VaultBootstrap} from "./BittyV1VaultBootstrap.sol";

/**
 * @title BittyV1VaultFactory
 * @notice Deploys main vaults as ERC-1967 UUPS proxies at a per-owner CREATE2 address. The proxy is
 *         deployed with EMPTY init data and initialized in the same transaction, so the counterfactual
 *         address depends only on the owner (not on the activation fee) — an owner can pre-fund the
 *         predicted address and anyone can then activate it.
 * @dev Renamed to BittyV1VaultFactory at cutover. The main vault's allowlist defaults ON.
 */
contract BittyV1VaultFactory is Initializable, EIP712 {
    bytes32 private constant _ACTIVATION_TYPEHASH =
        keccak256("Activation(address owner,address stableCoinAddress,uint256 feeAmount,bool allowlistEnabled)");

    address public constant DEPLOYER = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    address public bootstrapImplementation;

    address public vaultImplementation;
    address public wethAddress;

    event VaultActivated(address indexed owner, address vault);

    constructor() EIP712("BittyV1VaultFactory", "1") {}

    function initialize(address vaultImplementation_, address wethAddress_, address bootstrapImplementation_)
        external
        initializer
    {
        if (tx.origin != DEPLOYER) revert NotDeployer();
        if (vaultImplementation_ == address(0) || wethAddress_ == address(0) || bootstrapImplementation_ == address(0))
        {
            revert AddressZero();
        }
        bootstrapImplementation = bootstrapImplementation_;
        vaultImplementation = vaultImplementation_;
        wethAddress = wethAddress_;
    }

    function setVaultImplementation(address vaultImplementation_) external {
        if (tx.origin != DEPLOYER) revert NotDeployer();
        if (vaultImplementation_ == address(0)) revert AddressZero();
        vaultImplementation = vaultImplementation_;
    }

    function activateVault(bool allowlistEnabled) external returns (address vault) {
        return _deploy(msg.sender, address(0), 0, allowlistEnabled);
    }

    function activateVaultByAsset(
        address owner,
        address asset,
        uint256 amount,
        bool allowlistEnabled,
        bytes calldata signature
    ) external returns (address vault) {
        _checkActivationSignature(owner, asset, amount, allowlistEnabled, signature);
        return _deploy(owner, asset, amount, allowlistEnabled);
    }

    function _deploy(address owner, address asset, uint256 amount, bool allowlistEnabled)
        private
        returns (address vault)
    {
        bytes32 salt = keccak256(abi.encodePacked(owner));
        vault = _predict(salt);
        if (vault.code.length > 0) revert VaultAlreadyActivated();
        address deployed = address(new ERC1967Proxy{salt: salt}(bootstrapImplementation, ""));
        BittyV1VaultBootstrap(payable(deployed))
            .upgradeToAndCall(
                vaultImplementation,
                abi.encodeCall(BittyV1Vault.initialize, (owner, wethAddress, allowlistEnabled, asset, amount))
            );
        emit VaultActivated(owner, deployed);
        vault = deployed;
    }

    function _predict(bytes32 salt) private view returns (address) {
        bytes memory bytecode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(bootstrapImplementation, bytes("")));
        return Create2.computeAddress(salt, keccak256(bytecode));
    }

    function vaultAddress(address owner) external view returns (address) {
        return _predict(keccak256(abi.encodePacked(owner)));
    }

    function _checkActivationSignature(
        address owner,
        address stableCoinAddress,
        uint256 feeAmount,
        bool allowlistEnabled,
        bytes calldata signature
    ) private view {
        bytes32 structHash = keccak256(
            abi.encode(_ACTIVATION_TYPEHASH, owner, stableCoinAddress, feeAmount, allowlistEnabled)
        );
        if (!SignatureChecker.isValidSignatureNow(owner, _hashTypedDataV4(structHash), signature)) {
            revert InvalidActivationSignature();
        }
    }
}
