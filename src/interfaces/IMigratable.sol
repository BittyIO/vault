// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IMigrator} from "./IMigrator.sol";

interface IMigratable {
    function migrator() external view returns (IMigrator);

    function migrate() external;
}
