// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

interface IAaveV3 {
    function getPool() external view returns (IAavePool);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
