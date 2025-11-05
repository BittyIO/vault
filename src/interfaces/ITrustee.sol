// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IAssetManager} from "./IAssetManager.sol";
/**
 * @title Manage the fund of the Trust.
 * @dev
 * 1. Yield by Aave, compound.
 * 2. Trade by Uniswap, with limited slippage.
 */

interface ITrustee is IAssetManager {
    function changeTrusteeAddress(address newTrusteeAddress) external;
}
