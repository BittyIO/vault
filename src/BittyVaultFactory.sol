// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {BittyVault} from "./BittyVault.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {InvalidGrantor, DeploymentFailed} from "./interfaces/Errors.sol";

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
    address public wbtcAddress;
    address public usdtAddress;
    address public usdcAddress;
    address public aaveV3Address;
    address public uniswapV4RouterAddress;

    constructor() Ownable(tx.origin) {
    }

    function initialize(
        address wethAddress_,
        address wbtcAddress_,
        address usdtAddress_,
        address usdcAddress_,
        address aaveV3Address_,
        address uniswapV4RouterAddress_
    ) public initializer {
        wethAddress = wethAddress_;
        wbtcAddress = wbtcAddress_;
        usdtAddress = usdtAddress_;
        usdcAddress = usdcAddress_;
        aaveV3Address = aaveV3Address_;
        uniswapV4RouterAddress = uniswapV4RouterAddress_;
    }

    /**
     * @notice Deploys a new BittyVault for a specific grantor using CREATE2
     * @dev The vault address is deterministic based on the grantor address
     * @param grantor The address of the grantor who will initialize the vault
     * @return vault The address of the deployed BittyVault
     */
    function deployVault(address grantor) external returns (address vault) {
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
            .initialize(
                grantor, wethAddress, wbtcAddress, usdtAddress, usdcAddress, aaveV3Address, uniswapV4RouterAddress
            );

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

