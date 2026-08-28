// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {AddressZero} from "./interfaces/IBittyV1Vault.sol";
import {BittyV1Vault} from "./BittyV1Vault.sol";
import {
    IBittyV1VaultFactory,
    VaultAlreadyActivated,
    NotDeployer,
    InvalidActivationSignature
} from "./interfaces/IBittyV1VaultFactory.sol";

contract BittyV1VaultFactory is IBittyV1VaultFactory, Initializable, EIP712 {
    bytes32 private constant _ACTIVATION_TYPEHASH =
        keccak256("Activation(address owner,address stableCoinAddress,uint256 feeAmount)");

    constructor() EIP712("BittyV1VaultFactory", "1") {}

    address public constant DEPLOYER = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    address public vaultImplementation;
    address public wethAddress;

    event VaultActivated(address indexed owner);

    function initialize(address vaultImplementation_, address wethAddress_) external override initializer {
        if (tx.origin != DEPLOYER) revert NotDeployer();
        if (vaultImplementation_ == address(0)) revert AddressZero();
        if (wethAddress_ == address(0)) revert AddressZero();
        vaultImplementation = vaultImplementation_;
        wethAddress = wethAddress_;
    }

    function activateVault() external override {
        _deploy(msg.sender, address(0), 0);
    }

    function activateVaultByAsset(address owner, address asset, uint256 amount, bytes calldata signature)
        external
        override
    {
        _checkActivationSignature(owner, asset, amount, signature);
        _deploy(owner, asset, amount);
    }

    function _deploy(address owner, address asset, uint256 amount) private {
        bytes32 salt = keccak256(abi.encodePacked(owner));
        address vault = Clones.predictDeterministicAddress(vaultImplementation, salt, address(this));
        if (vault.code.length > 0) revert VaultAlreadyActivated();

        Clones.cloneDeterministic(vaultImplementation, salt);
        BittyV1Vault(payable(vault)).initialize(owner, wethAddress, asset, amount);
        emit VaultActivated(owner);
    }

    function _checkActivationSignature(
        address owner,
        address stableCoinAddress,
        uint256 feeAmount,
        bytes calldata signature
    ) private view {
        bytes32 structHash = keccak256(abi.encode(_ACTIVATION_TYPEHASH, owner, stableCoinAddress, feeAmount));
        if (!SignatureChecker.isValidSignatureNow(owner, _hashTypedDataV4(structHash), signature)) {
            revert InvalidActivationSignature();
        }
    }

    function vaultAddress(address owner) external view override returns (address vault) {
        return
            Clones.predictDeterministicAddress(vaultImplementation, keccak256(abi.encodePacked(owner)), address(this));
    }
}
