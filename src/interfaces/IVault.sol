// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IVersionized} from "./IVersionized.sol";

interface IVault is IVersionized {
    function turnETHToWETH() external;
    function turnWETHToETH() external;
    function addAssets(address[] memory assetAddresses) external;

    function removeAssets(address[] memory assetAddresses) external;

    function resetAssets(address[] memory assetAddresses) external;

    function addStableCoins(address[] memory stableCoinAddresses) external;

    function removeStableCoins(address[] memory stableCoinAddresses) external;

    function resetStableCoins(address[] memory stableCoinAddresses) external;

    function getAssets() external view returns (address[] memory);

    function getStableCoins() external view returns (address[] memory);
}
