// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IProvider} from "./IProvider.sol";

/**
 * @title ISwapProvider
 * @notice Interface for swap providers.
 * @dev This interface is used to swap the asset.
 */
interface ISwapProvider is IProvider {
    function swap(bytes memory data) external payable;
}
