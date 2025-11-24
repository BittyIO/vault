// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

interface IVault {
    function addAssets(address[] memory assetAddresses) external;

    function removeAssets(address[] memory assetAddresses) external;

    function addStableCoins(address[] memory stableCoinAddresses) external;

    function removeStableCoins(address[] memory stableCoinAddresses) external;

    function addYieldProviders(address[] memory yieldProviderAddresses) external;

    function removeYieldProviders(address[] memory yieldProviderAddresses) external;

    function addSwapProviders(address[] memory swapProviderAddresses) external;

    function removeSwapProviders(address[] memory swapProviderAddresses) external;
}
