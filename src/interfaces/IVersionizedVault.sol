// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IMigratable} from "./IMigratable.sol";

interface IVersionizedVault is IMigratable {
    function version() external view returns (uint256);
    function initialize(address previousVersionVaultAddress, bytes memory args) external;
}
