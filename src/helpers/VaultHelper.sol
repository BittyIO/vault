// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {TransferFailed, InsufficientStablecoinBalance} from "../interfaces/Errors.sol";

library VaultHelper {
    /**
     * @notice Get money implementation for BittyVault
     * @dev Transfers stablecoin amount to beneficiary, getting from yield providers and swapping assets if needed
     * @param vaultAddress The address of the vault contract
     * @param amount The amount to withdraw (in base units, will be converted to token decimals)
     * @param stableCoinAddress Address of the stablecoin
     * @param to Address to transfer the money to
     */
    function getMoney(address vaultAddress, uint256 amount, address stableCoinAddress, address to) public {
        ERC20 stableCoin = ERC20(stableCoinAddress);
        uint256 withdrawAmountDecimals = amount * 10 ** stableCoin.decimals();
        uint256 balance = stableCoin.balanceOf(vaultAddress);
        if (balance >= withdrawAmountDecimals) {
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
