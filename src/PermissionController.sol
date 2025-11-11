// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

abstract contract PermissionController {
    modifier onlyTrustee() virtual;
    modifier onlyInitialized() virtual;
    modifier onlyGrantor() virtual;
}
