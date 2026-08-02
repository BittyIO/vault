// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {AddressZero} from "../interfaces/IBittyV1Vault.sol";
import {AssetManagerStorage} from "./Storages.sol";

/**
 * @title AssetManagerShared
 * @notice Internal helpers shared by {AssetManagerLogic} (yield + config) and
 *         {AssetManagerTradeLogic} (trading). Internal-only, so they inline into each library's
 *         bytecode — no separate deployment or `--libraries` linking. Splitting the asset-manager
 *         surface across two deployed libraries keeps each under the EIP-170 24,576-byte limit.
 */
library AssetManagerShared {
    using Clones for address;

    /**
     * @dev Deploy (once) and cache the vault's per-protocol EIP-1167 clone. Every caller is already
     *      behind an `onlyInitialized` external, so there is no init check here.
     */
    function cloneProtocol(AssetManagerStorage storage logicStorage, address protocol)
        internal
        returns (address clonedProtocol)
    {
        clonedProtocol = logicStorage.clonedProtocols[protocol];
        if (clonedProtocol != address(0)) {
            return clonedProtocol;
        }
        clonedProtocol = protocol.clone();
        IBittyV1Protocol(clonedProtocol).initialize(address(this));
        logicStorage.clonedProtocols[protocol] = clonedProtocol;
        return clonedProtocol;
    }

    function addressBalance(address assetAddress) internal view returns (uint256) {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        return IERC20(assetAddress).balanceOf(address(this));
    }
}
