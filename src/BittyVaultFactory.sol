// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {BittyVault} from "./BittyVault.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {InvalidGrantor, DeploymentFailed, AddressZero} from "./interfaces/Errors.sol";

/**
 * @title BittyVaultFactory
 * @notice Factory contract for deploying BittyVault instances using CREATE2
 * @dev Each grantor address will generate a unique, deterministic BittyVault address
 */
contract BittyVaultFactory is Initializable, Ownable {
    /**
     * @notice Emitted when a new BittyVault is deployed
     * @param vault The address of the deployed vault
     * @param grantor The grantor address that will own this vault
     */
    event VaultDeployed(address indexed vault, address indexed grantor);

    address public wethAddress;
    mapping(address => bool) public assetAddresses;
    mapping(address => bool) public stableCoinAddresses;
    mapping(address => bool) public yieldProviders;
    mapping(address => bool) public swapProviders;

    constructor() {
        transferOwnership(tx.origin);
    }

    function initialize(
        address wethAddress_,
        address[] memory assetAddresses_,
        address[] memory stableCoinAddresses_,
        address[] memory yieldProviders_,
        address[] memory swapProviders_
    ) public initializer {
        if (wethAddress_ == address(0)) {
            revert AddressZero();
        }
        wethAddress = wethAddress_;
        for (uint256 i = 0; i < assetAddresses_.length; i++) {
            if (assetAddresses_[i] == address(0)) {
                revert AddressZero();
            }
            assetAddresses[assetAddresses_[i]] = true;
        }
        for (uint256 i = 0; i < stableCoinAddresses_.length; i++) {
            if (stableCoinAddresses_[i] == address(0)) {
                revert AddressZero();
            }
            stableCoinAddresses[stableCoinAddresses_[i]] = true;
        }
        for (uint256 i = 0; i < yieldProviders_.length; i++) {
            if (yieldProviders_[i] == address(0)) {
                revert AddressZero();
            }
            yieldProviders[yieldProviders_[i]] = true;
        }
        for (uint256 i = 0; i < swapProviders_.length; i++) {
            if (swapProviders_[i] == address(0)) {
                revert AddressZero();
            }
            swapProviders[swapProviders_[i]] = true;
        }
    }

    function deployVault(
        address grantor,
        address wethAddress_,
        address[] memory assetAddresses_,
        address[] memory stableCoinAddresses_,
        address[] memory yieldProviders_,
        address[] memory swapProviders_
    ) external returns (address vault) {
        if (grantor == address(0)) {
            revert InvalidGrantor();
        }
        bytes32 salt = keccak256(abi.encodePacked(grantor));
        bytes memory bytecode = type(BittyVault).creationCode;
        bytes32 bytecodeHash = keccak256(bytecode);
        address computedAddress = computeAddress(salt, bytecodeHash);
        if (computedAddress.code.length > 0) {
            return computedAddress;
        }
        assembly {
            vault := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        BittyVault(payable(vault))
            .initialize(grantor, wethAddress_, assetAddresses_, stableCoinAddresses_, yieldProviders_, swapProviders_);

        if (vault == address(0)) {
            revert DeploymentFailed();
        }

        emit VaultDeployed(vault, grantor);
    }

    /**
     * @notice Computes the address where a BittyVault will be deployed for a given grantor
     * @param grantor The address of the grantor
     * @return The deterministic address where the vault will be deployed
     */
    function computeVaultAddress(address grantor) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(grantor));
        bytes32 bytecodeHash = keccak256(type(BittyVault).creationCode);
        return computeAddress(salt, bytecodeHash);
    }

    /**
     * @notice Computes the CREATE2 address
     * @param salt The salt used for CREATE2
     * @param bytecodeHash The hash of the contract bytecode
     * @return addr The computed address
     */
    function computeAddress(bytes32 salt, bytes32 bytecodeHash) internal view returns (address addr) {
        assembly {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), bytecodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, address())
            let start := add(ptr, 0x0b)
            mstore8(start, 0xff)
            addr := and(keccak256(start, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}

