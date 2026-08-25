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

/**
 * @title BittyV1VaultFactory
 * @notice Activates BittyV1Vault instances at an address deterministic on the owner alone, so each
 *         address has exactly one vault — and so a vault can be funded before it exists.
 */
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

    function activateVaultByStablecoin(
        address owner,
        address stableCoinAddress,
        uint256 feeAmount,
        bytes calldata signature
    ) external override {
        _checkActivationSignature(owner, stableCoinAddress, feeAmount, signature);
        _deploy(owner, stableCoinAddress, feeAmount);
    }

    function _deploy(address owner, address stableCoinAddress, uint256 feeAmount) private {
        bytes32 salt = keccak256(abi.encodePacked(owner));
        address vault = Clones.predictDeterministicAddress(vaultImplementation, salt, address(this));
        if (vault.code.length > 0) revert VaultAlreadyActivated();

        Clones.cloneDeterministic(vaultImplementation, salt);
        BittyV1Vault(payable(vault)).initialize(owner, wethAddress, stableCoinAddress, feeAmount);
        emit VaultActivated(owner);
    }

    /**
     * @dev SignatureChecker rather than plain ECDSA so an owner that is itself a contract wallet
     *      (Safe, and anything else implementing ERC-1271) can be onboarded the same way.
     *
     *      No nonce: a vault activates exactly once, so a replayed signature simply hits
     *      VaultAlreadyActivated. That saves a storage slot and a write on the one path where the
     *      caller is paying for someone else's gas.
     */
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
