// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IMigratable} from "./IMigratable.sol";

interface IVersionized is IMigratable {
    function version() external view returns (uint256);
    function initializeFromPreviousVersion(address previousVersionAddress, bytes memory args) external;
}
