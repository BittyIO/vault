// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {
    AlreadyInitialized,
    AddressZero,
    NotInitialized,
    NotWhiteListed,
    InsufficientBalance
} from "../interfaces/Errors.sol";
import {IWhiteList} from "../interfaces/IWhiteList.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {VaultStorage} from "./Storages.sol";
import {VaultHelper} from "../helpers/VaultHelper.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";

library VaultLogic {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    using Address for address;

    modifier onlyInitialized(VaultStorage storage logicStorage) {
        _onlyInitialized(logicStorage);
        _;
    }

    function _onlyInitialized(VaultStorage storage logicStorage) private view {
        if (!logicStorage.isInitialized) {
            revert NotInitialized();
        }
    }

    modifier onlyNotInitialized(VaultStorage storage logicStorage) {
        _onlyNotInitialized(logicStorage);
        _;
    }

    function _onlyNotInitialized(VaultStorage storage logicStorage) private view {
        if (logicStorage.isInitialized) {
            revert AlreadyInitialized();
        }
    }

    function initialize(VaultStorage storage logicStorage, address grantor, address weth, address whiteListAddress)
        external
        onlyNotInitialized(logicStorage)
    {
        if (grantor == address(0)) {
            revert AddressZero();
        }
        logicStorage.grantor = grantor;
        if (weth == address(0)) {
            revert AddressZero();
        }
        logicStorage.weth = weth;
        if (whiteListAddress == address(0)) {
            revert AddressZero();
        }
        logicStorage.whiteList = IWhiteList(whiteListAddress);
        logicStorage.isInitialized = true;
    }

    function changeGrantorAddress(VaultStorage storage logicStorage, address grantor)
        external
        onlyInitialized(logicStorage)
    {
        if (grantor == address(0)) {
            revert AddressZero();
        }
        logicStorage.grantor = grantor;
    }

    function turnETHToWETH(VaultStorage storage logicStorage) external onlyInitialized(logicStorage) {
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            WETH(payable(logicStorage.weth)).deposit{value: ethBalance}();
        }
    }

    function turnWETHToETH(VaultStorage storage logicStorage) external onlyInitialized(logicStorage) {
        uint256 ethBalance = WETH(payable(logicStorage.weth)).balanceOf(address(this));
        if (ethBalance > 0) {
            WETH(payable(logicStorage.weth)).withdraw(ethBalance);
        }
    }

    function getMoney(VaultStorage storage vaultStorage, uint256 amount, address stableCoinAddress, address to)
        external
        onlyInitialized(vaultStorage)
    {
        VaultHelper.getMoney(address(this), amount, stableCoinAddress, to);
    }

    function getPercentageMoney(VaultStorage storage vaultStorage, uint256 percentage, address to)
        external
        onlyInitialized(vaultStorage)
    {
        VaultHelper.getPercentageMoney(
            address(this), vaultStorage.stableCoins.values(), vaultStorage.assets.values(), percentage, to
        );
    }

    function withdraw(VaultStorage storage logicStorage, address assetAddress, uint256 amount, address to)
        external
        onlyInitialized(logicStorage)
    {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        uint256 balance = IERC20(assetAddress).balanceOf(address(this));
        if (balance < amount) {
            revert InsufficientBalance();
        }
        IERC20(assetAddress).safeTransfer(to, amount);
    }

    function revoke(VaultStorage storage logicStorage, address moneyWithdrawTo) external {
        if (moneyWithdrawTo == address(0)) {
            revert AddressZero();
        }
        for (uint256 i = 0; i < logicStorage.assets.length(); i++) {
            _transferAllERC20(logicStorage.assets.at(i), moneyWithdrawTo);
        }

        for (uint256 i = 0; i < logicStorage.stableCoins.length(); i++) {
            _transferAllERC20(logicStorage.stableCoins.at(i), moneyWithdrawTo);
        }

        // Transfer any remaining ETH
        if (address(this).balance > 0) {
            Address.sendValue(payable(moneyWithdrawTo), address(this).balance);
        }
    }

    function _transferAllERC20(address tokenAddress, address to) private {
        if (tokenAddress == address(0)) {
            return;
        }
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            token.safeTransfer(to, balance);
        }
    }

    function addAssets(VaultStorage storage logicStorage, address[] memory assetAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (!logicStorage.whiteList.isAssetWhiteListed(assetAddresses[i])) {
                revert NotWhiteListed();
            }
            logicStorage.assets.add(assetAddresses[i]);
        }
    }

    function removeAssets(VaultStorage storage logicStorage, address[] memory assetAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            logicStorage.assets.remove(assetAddresses[i]);
        }
    }

    function resetAssets(VaultStorage storage logicStorage, address[] memory assetAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            logicStorage.assets.remove(assetAddresses[i]);
        }
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (!logicStorage.whiteList.isAssetWhiteListed(assetAddresses[i])) {
                revert NotWhiteListed();
            }
            logicStorage.assets.add(assetAddresses[i]);
        }
    }

    function addStableCoins(VaultStorage storage logicStorage, address[] memory stableCoinAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (!logicStorage.whiteList.isStableCoinWhiteListed(stableCoinAddresses[i])) {
                revert NotWhiteListed();
            }
            logicStorage.stableCoins.add(stableCoinAddresses[i]);
        }
    }

    function removeStableCoins(VaultStorage storage logicStorage, address[] memory stableCoinAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            logicStorage.stableCoins.remove(stableCoinAddresses[i]);
        }
    }

    function resetStableCoins(VaultStorage storage logicStorage, address[] memory stableCoinAddresses)
        external
        onlyInitialized(logicStorage)
    {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            logicStorage.stableCoins.remove(stableCoinAddresses[i]);
        }
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (!logicStorage.whiteList.isStableCoinWhiteListed(stableCoinAddresses[i])) {
                revert NotWhiteListed();
            }
            logicStorage.stableCoins.add(stableCoinAddresses[i]);
        }
    }

    function getAssets(VaultStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.assets.values();
    }

    function getStableCoins(VaultStorage storage logicStorage) external view returns (address[] memory) {
        return logicStorage.stableCoins.values();
    }

    function checkAsset(VaultStorage storage logicStorage, address assetAddress) external view {
        if (logicStorage.whiteList.isAssetWhiteListed(assetAddress) && logicStorage.assets.contains(assetAddress)) {
            return;
        }
        if (
            logicStorage.whiteList.isStableCoinWhiteListed(assetAddress)
                && logicStorage.stableCoins.contains(assetAddress)
        ) {
            return;
        }
        revert NotWhiteListed();
    }
}
