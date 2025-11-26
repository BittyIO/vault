// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {BittyVault} from "./BittyVault.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {InvalidGrantor, DeploymentFailed, AddressZero, NotInitialized, NotWhiteListed} from "./interfaces/Errors.sol";
import {IWhiteList} from "./interfaces/IWhiteList.sol";

/**
 * @title BittyVaultFactory
 * @notice Factory contract for deploying BittyVault instances using CREATE2
 * @dev Each grantor address will generate a unique, deterministic BittyVault address
 */
contract BittyVaultFactory is Initializable {
    IWhiteList public whiteList;
    /**
     * @notice Emitted when a new BittyVault is deployed
     * @param vault The address of the deployed vault
     * @param grantor The grantor address that will own this vault
     */
    event VaultDeployed(address indexed vault, address indexed grantor);

    address public wethAddress;

    function initialize(address wethAddress_, address whiteListAddress_) public initializer {
        if (wethAddress_ == address(0)) {
            revert AddressZero();
        }
        wethAddress = wethAddress_;
        whiteList = IWhiteList(whiteListAddress_);
    }

    function deployVault(
        address grantor,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory yieldProviders,
        address[] memory swapProviders
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

        _checkWhiteList(assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);

        BittyVault(payable(vault))
            .initialize(
                grantor,
                wethAddress,
                address(whiteList),
                assetAddresses,
                stableCoinAddresses,
                yieldProviders,
                swapProviders
            );

        if (vault == address(0)) {
            revert DeploymentFailed();
        }

        emit VaultDeployed(vault, grantor);
    }

    function _checkWhiteList(
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory yieldProviders,
        address[] memory swapProviders
    ) internal view {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (!whiteList.isAssetWhiteListed(assetAddresses[i])) {
                revert NotWhiteListed();
            }
        }
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (!whiteList.isStableCoinWhiteListed(stableCoinAddresses[i])) {
                revert NotWhiteListed();
            }
        }
        for (uint256 i = 0; i < yieldProviders.length; i++) {
            if (!whiteList.isYieldProviderWhiteListed(yieldProviders[i])) {
                revert NotWhiteListed();
            }
        }
        for (uint256 i = 0; i < swapProviders.length; i++) {
            if (!whiteList.isSwapProviderWhiteListed(swapProviders[i])) {
                revert NotWhiteListed();
            }
        }
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

