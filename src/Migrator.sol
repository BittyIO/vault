// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IMigrator} from "./interfaces/IMigrator.sol";

contract Migrator is IMigrator, Ownable {
    mapping(address => address) public nextVaults;

    function setNextVault(address _vault, address _nextVault) external override onlyOwner {
        nextVaults[_vault] = _nextVault;
    }

    function nextVault(address _vault) external view override returns (address) {
        return nextVaults[_vault];
    }
}
