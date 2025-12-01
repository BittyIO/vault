// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {OracleLibrary} from "../libs/OracleLibrary.sol";
import {IPoolManager, PoolKey, PoolIdLibrary} from "../libs/Uniswap.sol";

library UniswapQuoteHelper {
    /**
     * @notice Get quote from Uniswap V4 using OracleLibrary
     * @dev Uses Uniswap V4 pool manager to find pools and OracleLibrary to get quotes
     * @param poolManager The Uniswap V4 pool manager
     * @param assetAddress Address of the asset to sell
     * @param stableCoinAddress Address of the stablecoin to buy
     * @param amountIn Amount of asset to sell
     * @return quoteAmount Expected amount of stablecoin to receive
     */
    function getQuoteFromUniswapV4(
        IPoolManager poolManager,
        address assetAddress,
        address stableCoinAddress,
        uint256 amountIn
    ) public view returns (uint256) {
        uint24[] memory fees = new uint24[](3);
        fees[0] = 500; // 0.05%
        fees[1] = 3000; // 0.3%
        fees[2] = 10000; // 1%

        int24[] memory tickSpacings = new int24[](3);
        tickSpacings[0] = 10; // Standard tick spacing for 0.05% fee
        tickSpacings[1] = 60; // Standard tick spacing for 0.3% fee
        tickSpacings[2] = 200; // Standard tick spacing for 1% fee

        // Try different fee tiers to find a pool
        for (uint256 i = 0; i < fees.length; i++) {
            // Create PoolKey - currencies must be sorted
            address currency0 = assetAddress < stableCoinAddress ? assetAddress : stableCoinAddress;
            address currency1 = assetAddress < stableCoinAddress ? stableCoinAddress : assetAddress;

            PoolKey memory poolKey = PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: fees[i],
                tickSpacing: tickSpacings[i],
                hooks: address(0)
            });

            uint256 quote = getQuoteFromV4Pool(poolManager, poolKey, amountIn, assetAddress, stableCoinAddress);
            if (quote > 0) {
                return quote;
            }
        }

        return 0;
    }

    /**
     * @notice Get quote from a specific Uniswap V4 pool using OracleLibrary
     * @dev Uses OracleLibrary.consult() to get current price (V4 doesn't have historical observations)
     */
    function getQuoteFromV4Pool(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        uint256 amountIn,
        address assetAddress,
        address stableCoinAddress
    ) public view returns (uint256) {
        // Get current tick from the pool
        int24 tick = OracleLibrary.consult(poolManager, poolKey);

        if (tick == 0) {
            return 0; // Pool might not be initialized or doesn't exist
        }

        // Use OracleLibrary to get quote at current tick
        // Convert amountIn to uint128 (max value for OracleLibrary)
        uint128 baseAmount = amountIn > type(uint128).max ? type(uint128).max : uint128(amountIn);

        uint256 quoteAmount = OracleLibrary.getQuoteAtTick(tick, baseAmount, assetAddress, stableCoinAddress);

        if (amountIn > type(uint128).max) {
            // Scale up proportionally
            quoteAmount = (quoteAmount * amountIn) / uint256(baseAmount);
        }

        return quoteAmount;
    }
}

