// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IWhiteList} from "../interfaces/IWhiteList.sol";
import {NotWhiteListed} from "../interfaces/Errors.sol";

library FactoryHelper {
    /**
     * @notice Check if all addresses are whitelisted
     * @dev Validates assets, stablecoins, yield providers, and swap providers
     */
    function checkWhiteList(
        IWhiteList whiteList,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory yieldProviders,
        address[] memory swapProviders
    ) public view {
        uint256 i;
        for (i = 0; i < assetAddresses.length; i++) {
            if (!whiteList.isAssetWhiteListed(assetAddresses[i])) revert NotWhiteListed();
        }
        for (i = 0; i < stableCoinAddresses.length; i++) {
            if (!whiteList.isStableCoinWhiteListed(stableCoinAddresses[i])) revert NotWhiteListed();
        }
        for (i = 0; i < yieldProviders.length; i++) {
            if (!whiteList.isYieldProviderWhiteListed(yieldProviders[i])) revert NotWhiteListed();
        }
        for (i = 0; i < swapProviders.length; i++) {
            if (!whiteList.isSwapProviderWhiteListed(swapProviders[i])) revert NotWhiteListed();
        }
    }

    /**
     * @notice Compute CREATE2 address for a vault
     * @dev Uses CREATE2 formula: keccak256(0xff ++ deployer ++ salt ++ keccak256(bytecode))
     */
    function computeAddress(bytes32 salt, bytes32 bytecodeHash, address deployer) public pure returns (address addr) {
        assembly {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), bytecodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, deployer)
            let start := add(ptr, 0x0b)
            mstore8(start, 0xff)
            addr := and(keccak256(start, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}

