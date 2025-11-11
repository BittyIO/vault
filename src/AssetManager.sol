// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IAssetManager} from "./interfaces/IAssetManager.sol";
import {ITrustee} from "./interfaces/ITrustee.sol";
import {ITrust} from "./interfaces/ITrust.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IAaveV3} from "./libs/Aave.sol";
import {IUniswapV4Router04} from "./libs/Uniswap.sol";

interface IWETH {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
}

abstract contract AssetManager is IAssetManager, Initializable {
    modifier onlyTrustee() virtual;
    modifier onlyInitialized() virtual;
    modifier onlyGrantor() virtual;

    mapping(AssetType => address) public assets;
    // only WETH and WBTC rebalance will be recorded
    mapping(AssetType => uint256) public lastRebalances;
    ITrustee.RebalanceLimit public rebalanceLimit;
    IAaveV3 public aave;
    IUniswapV4Router04 public uniswapV4Router;

    function initialize(
        address wethAddress,
        address wbtcAddress,
        address usdtAddress,
        address usdcAddress,
        address aaveV3Address,
        address uniswapV4RouterAddress
    ) external initializer {
        if (wethAddress != address(0)) {
            assets[IAssetManager.AssetType.WETH] = wethAddress;
        }
        if (wbtcAddress != address(0)) {
            assets[IAssetManager.AssetType.WBTC] = wbtcAddress;
        }
        if (usdtAddress != address(0)) {
            assets[IAssetManager.AssetType.USDT] = usdtAddress;
        }
        if (usdcAddress != address(0)) {
            assets[IAssetManager.AssetType.USDC] = usdcAddress;
        }
        if (aaveV3Address != address(0)) {
            aave = IAaveV3(aaveV3Address);
        }
        if (uniswapV4RouterAddress != address(0)) {
            uniswapV4Router = IUniswapV4Router04(uniswapV4RouterAddress);
        }
    }

    function setRebalanceRules(ITrustee.RebalanceLimit memory rebalanceLimit_) external onlyInitialized onlyGrantor {
        rebalanceLimit = rebalanceLimit_;
    }

    function supply(address assetAddress, uint256 amount) external override onlyInitialized onlyTrustee {
        if (assetAddress == address(0)) {
            revert ITrust.AddressZero();
        }
        if (amount == 0) {
            revert ITrust.AmountIsZero();
        }
        aave.getPool().supply(assetAddress, amount, address(this), 0);
    }

    function withdraw(address assetAddress, uint256 amount) external override onlyInitialized onlyTrustee {
        if (assetAddress == address(0)) {
            revert ITrust.AddressZero();
        }
        if (amount == 0) {
            revert ITrust.AmountIsZero();
        }
        aave.getPool().withdraw(assetAddress, amount, address(this));
    }

    function assetBalance(AssetType assetType) internal view returns (uint256) {
        return IERC20(assets[assetType]).balanceOf(address(this));
    }

    function addressBalance(address assetAddress) internal view returns (uint256) {
        return IERC20(assetAddress).balanceOf(address(this));
    }

    function rebalance(AssetType from, AssetType to, uint256 sellAmount, uint256 buyAmountMin, bytes calldata data)
        external
        override
        onlyInitialized
        onlyTrustee
    {
        if ((from == AssetType.WETH || to == AssetType.WETH) && lastRebalances[AssetType.WETH] != 0) {
            if (block.timestamp - lastRebalances[AssetType.WETH] < rebalanceLimit.minimalTimestampBetweenRebalances) {
                revert IAssetManager.RebalanceInMinimalTime();
            }
        }
        if ((from == AssetType.WBTC || to == AssetType.WBTC) && lastRebalances[AssetType.WBTC] != 0) {
            if (block.timestamp - lastRebalances[AssetType.WBTC] < rebalanceLimit.minimalTimestampBetweenRebalances) {
                revert IAssetManager.RebalanceInMinimalTime();
            }
        }
        if (from == AssetType.WBTC) {
            if (assetBalance(AssetType.WBTC) < (rebalanceLimit.minimalWBTCBalance + sellAmount)) {
                revert IAssetManager.MinimalWBTCBalanceLimit();
            }
        } else if (from == AssetType.WETH) {
            if (assetBalance(AssetType.WETH) < (rebalanceLimit.minimalWETHBalance + sellAmount)) {
                revert IAssetManager.MinimalWETHBalanceLimit();
            }
        } else if ((from == AssetType.USDT || from == AssetType.USDC) && (to == AssetType.WETH || to == AssetType.WBTC))
        {
            if (
                assetBalance(AssetType.USDT) + assetBalance(AssetType.USDC)
                    < (rebalanceLimit.minimalStableCoinBalance + sellAmount)
            ) {
                revert IAssetManager.MinimalStableCoinBalanceLimit();
            }
        }

        _swap(assets[from], sellAmount, to, buyAmountMin, data);

        if (from == AssetType.WETH || to == AssetType.WETH) {
            lastRebalances[AssetType.WETH] = block.timestamp;
        }
        if (from == AssetType.WBTC || to == AssetType.WBTC) {
            lastRebalances[AssetType.WBTC] = block.timestamp;
        }
    }

    function sellAssetsNotWhiteListed(
        address sellAssetAddress,
        uint256 sellAmount,
        AssetType toAssetType,
        uint256 buyAmountMin,
        bytes calldata data
    ) external override onlyInitialized onlyTrustee {
        _swap(sellAssetAddress, sellAmount, toAssetType, buyAmountMin, data);
    }

    function _swap(
        address sellAssetAddress,
        uint256 sellAmount,
        AssetType toAssetType,
        uint256 buyAmountMin,
        bytes calldata data
    ) internal {
        if (sellAssetAddress == address(0)) {
            revert ITrust.AddressZero();
        }
        if (sellAmount == 0 || buyAmountMin == 0) {
            revert ITrust.AmountIsZero();
        }
        uint256 sellAssetBalanceBefore = addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore < sellAmount) {
            revert IAssetManager.InsufficientBalance();
        }
        uint256 buyAssetBalanceBefore = assetBalance(toAssetType);
        IUniswapV4Router04(uniswapV4Router).swap(data, block.timestamp);
        uint256 sellAssetBalanceAfter = addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore - sellAssetBalanceAfter != sellAmount) {
            revert IAssetManager.SellAmountMismatch();
        }
        uint256 buyAssetBalanceAfter = assetBalance(toAssetType);
        if (buyAssetBalanceAfter - buyAssetBalanceBefore < buyAmountMin) {
            revert IAssetManager.BuyAmountNotEnough();
        }
    }

    function getETHBalance() external view virtual override returns (uint256) {
        return address(this).balance;
    }

    function turnETHToWETH() external virtual override onlyInitialized {
        if (address(assets[AssetType.WETH]) == address(0)) {
            revert WETHNotSet();
        }
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            IWETH(assets[AssetType.WETH]).deposit{value: ethBalance}();
        }
    }

    function getWETHBalance() external view virtual override returns (uint256) {
        if (address(assets[AssetType.WETH]) == address(0)) {
            revert WETHNotSet();
        }
        return IWETH(assets[AssetType.WETH]).balanceOf(address(this));
    }

    receive() external payable {}

    fallback() external payable {}
}
