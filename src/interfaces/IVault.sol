// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

interface IVault {
    /**
     * @notice Set the WETH contract address.
     * @dev Can only be called once.
     * @param wethAddress The WETH contract address.
     */
    function setWETH(address wethAddress) external;

    /**
     * @notice Set the USDT contract address.
     * @dev Can only be called once.
     * @param usdtAddress The USDT contract address.
     */
    function setUSDT(address usdtAddress) external;

    /**
     * @notice Set the USDC contract address.
     * @dev Can only be called once.
     * @param usdcAddress The USDC contract address.
     */
    function setUSDC(address usdcAddress) external;
}
