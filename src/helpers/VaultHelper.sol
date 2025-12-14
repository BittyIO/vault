// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IYieldProvider} from "../interfaces/IAssetManager.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {ISwapProvider} from "../interfaces/IAssetManager.sol";
import {IPoolManager} from "../libs/uniswap/v4/Uniswap.sol";
import {UniswapQuoteHelper} from "./UniswapQuoteHelper.sol";
import {TransferFailed, InsufficientStablecoinBalance} from "../interfaces/Errors.sol";

library VaultHelper {
    function getMoneyFromYieldProvider(address[] memory _yieldProviders, address stableCoinAddress, uint256 amount)
        public
        returns (uint256)
    {
        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < _yieldProviders.length; i++) {
            address yieldProvider = _yieldProviders[i];
            uint256 yieldProviderBalance = IYieldProvider(yieldProvider).getBalance(stableCoinAddress);
            if (yieldProviderBalance == 0) {
                continue;
            }
            bool withdrawEnough = yieldProviderBalance >= amount;
            uint256 withdrawAmount = withdrawEnough ? amount : yieldProviderBalance;
            IYieldProvider(yieldProvider).withdraw(stableCoinAddress, withdrawAmount);
            totalWithdrawn += withdrawAmount;
            if (withdrawEnough) {
                return totalWithdrawn;
            } else {
                amount -= withdrawAmount;
            }
        }
        return totalWithdrawn;
    }

    /**
     * @notice Get money from swap providers by swapping assets to stablecoin
     * @dev Iterates through all assets and swaps them one by one until enough stablecoin is obtained
     * @param _swapProviders Addresses of the swap providers
     * @param _assets Addresses of the assets
     * @param stableCoinAddress Address of the stablecoin to receive
     * @param amount Amount of stablecoin needed (in base units, will be converted to token decimals)
     * @return totalSwapped Total amount of stablecoin obtained from swaps
     */
    function getMoneyFromSwapProvider(
        IPoolManager poolManager,
        address vaultAddress,
        address[] memory _swapProviders,
        address[] memory _assets,
        address stableCoinAddress,
        uint256 amount
    ) public returns (uint256) {
        uint256 totalSwapped = 0;
        if (_swapProviders.length == 0) {
            return 0;
        }
        address swapProvider = _swapProviders[0];

        for (uint256 i = 0; i < _assets.length; i++) {
            address assetAddress = _assets[i];
            uint256 assetBalance = IERC20(assetAddress).balanceOf(vaultAddress);

            if (assetBalance == 0) {
                continue;
            }

            uint256 stableCoinBalanceBefore = IERC20(stableCoinAddress).balanceOf(vaultAddress);

            uint256 quoteForFullBalance =
                UniswapQuoteHelper.getQuoteFromUniswapV4(poolManager, assetAddress, stableCoinAddress, assetBalance);

            if (quoteForFullBalance == 0) {
                continue;
            }

            uint256 swapAmount = (amount * assetBalance * 101) / (quoteForFullBalance * 100);

            if (swapAmount > assetBalance) {
                swapAmount = assetBalance;
            }

            uint256 expectedOutput =
                UniswapQuoteHelper.getQuoteFromUniswapV4(poolManager, assetAddress, stableCoinAddress, swapAmount);
            uint256 minOutput = expectedOutput > 0 ? (expectedOutput * 95) / 100 : 0;

            bytes memory swapData = abi.encode(assetAddress, swapAmount, stableCoinAddress, minOutput);

            try ISwapProvider(swapProvider).swap(swapData) {
                uint256 stableCoinBalanceAfter = IERC20(stableCoinAddress).balanceOf(vaultAddress);
                uint256 swapped = stableCoinBalanceAfter > stableCoinBalanceBefore
                    ? stableCoinBalanceAfter - stableCoinBalanceBefore
                    : 0;

                totalSwapped += swapped;

                if (swapped >= amount) {
                    return totalSwapped;
                } else {
                    amount -= swapped;
                }
            } catch {
                continue;
            }
        }

        return totalSwapped;
    }

    /**
     * @notice Get money implementation for BittyVault
     * @dev Transfers stablecoin amount to beneficiary, getting from yield providers and swapping assets if needed
     * @param vaultAddress The address of the vault contract
     * @param poolManager The Uniswap V4 pool manager
     * @param yieldProviders Array of yield provider addresses
     * @param swapProviders Array of swap provider addresses
     * @param assets Array of asset addresses
     * @param amount The amount to withdraw (in base units, will be converted to token decimals)
     * @param stableCoinAddress Address of the stablecoin
     * @param to Address to transfer the money to
     */
    function getMoney(
        address vaultAddress,
        IPoolManager poolManager,
        address[] memory yieldProviders,
        address[] memory swapProviders,
        address[] memory assets,
        uint256 amount,
        address stableCoinAddress,
        address to
    ) public {
        uint256 withdrawAmountDecimals = amount * 10 ** ERC20(stableCoinAddress).decimals();
        IERC20 stableCoin = IERC20(stableCoinAddress);
        uint256 balance = stableCoin.balanceOf(vaultAddress);
        if (balance >= withdrawAmountDecimals) {
            _transferToken(stableCoinAddress, to, withdrawAmountDecimals);
            return;
        }
        uint256 amountNeeded = withdrawAmountDecimals - balance;
        uint256 amountWithdrawnFromYieldProviders =
            getMoneyFromYieldProvider(yieldProviders, stableCoinAddress, amountNeeded);
        if (amountWithdrawnFromYieldProviders >= amountNeeded) {
            _transferToken(stableCoinAddress, to, withdrawAmountDecimals);
            return;
        }
        uint256 amountNeededFromSwapProviders = amountNeeded - amountWithdrawnFromYieldProviders;
        uint256 amountWithdrawnFromSwapProviders = getMoneyFromSwapProvider(
            poolManager, vaultAddress, swapProviders, assets, stableCoinAddress, amountNeededFromSwapProviders
        );
        if (amountWithdrawnFromSwapProviders >= amountNeededFromSwapProviders) {
            _transferToken(stableCoinAddress, to, withdrawAmountDecimals);
            return;
        }
        revert InsufficientStablecoinBalance();
    }

    function _transferToken(address tokenAddress, address to, uint256 amount) private {
        // With DELEGATECALL, this executes in the vault's context, so transfer works directly
        IERC20 token = IERC20(tokenAddress);
        if (!token.transfer(to, amount)) {
            revert TransferFailed();
        }
    }

    /**
     * @notice Get percentage money implementation for BittyVault
     * @dev Transfers percentage of all stablecoins and assets to beneficiary
     * @param vaultAddress The address of the vault contract
     * @param stableCoins Array of stablecoin addresses
     * @param assets Array of asset addresses
     * @param percentage The percentage to transfer (in basis points, 10000 = 100%)
     * @param to Address to transfer the money to
     */
    function getPercentageMoney(
        address vaultAddress,
        address[] memory stableCoins,
        address[] memory assets,
        uint256 percentage,
        address to
    ) public {
        // Transfer percentage from all stablecoins
        for (uint256 i = 0; i < stableCoins.length; i++) {
            address stableCoinAddress = stableCoins[i];
            IERC20 stableCoin = IERC20(stableCoinAddress);
            uint256 balance = stableCoin.balanceOf(vaultAddress);
            uint256 amount = balance * percentage / 10000;
            if (amount > 0) {
                _transferToken(stableCoinAddress, to, amount);
            }
        }

        // Transfer percentage from all assets
        for (uint256 i = 0; i < assets.length; i++) {
            address assetAddress = assets[i];
            IERC20 asset = IERC20(assetAddress);
            uint256 balance = asset.balanceOf(vaultAddress);
            uint256 amount = balance * percentage / 10000;
            if (amount > 0) {
                _transferToken(assetAddress, to, amount);
            }
        }
    }
}
