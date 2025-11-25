// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IVersionizedVault} from "./IVersionizedVault.sol";

interface IVault is IVersionizedVault {
    function addAssets(address[] memory assetAddresses) external;

    function removeAssets(address[] memory assetAddresses) external;

    function addStableCoins(address[] memory stableCoinAddresses) external;

    function removeStableCoins(address[] memory stableCoinAddresses) external;

    function addYieldProviders(address[] memory yieldProviderAddresses) external;

    function removeYieldProviders(address[] memory yieldProviderAddresses) external;

    function addSwapProviders(address[] memory swapProviderAddresses) external;

    function removeSwapProviders(address[] memory swapProviderAddresses) external;
}
