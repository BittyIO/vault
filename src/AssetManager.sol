// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IAssetManager} from "./interfaces/IAssetManager.sol";
import {ITrustee} from "./interfaces/ITrustee.sol";
import {Trust} from "./Trust.sol";
import {IERC20} from "./common/IERC20.sol";
import {IAaveV3} from "./libs/Aave.sol";
import {IUniswapV4Router04} from "./libs/Uniswap.sol";

interface IWETH {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
}

abstract contract AssetManager is IAssetManager {
    error WETHNotSet();
    error AssetAlreadySet();
    error InvalidAssetType();

    modifier onlyTrustee() virtual;
    modifier onlyInitialized() virtual;

    mapping(AssetType => address) public assets;
    ITrustee.RebalanceLimit public rebalanceLimit;
    IAaveV3 public aave;
    IUniswapV4Router04 public uniswapV4Router;

    function setAaveV3(address aaveV3Address) external onlyInitialized onlyTrustee {
        if (aaveV3Address == address(0)) {
            revert Trust.AddressZero();
        }
        aave = IAaveV3(aaveV3Address);
    }

    function setUniswapV4Router(address uniswapV4RouterAddress) external onlyInitialized onlyTrustee {
        if (uniswapV4RouterAddress == address(0)) {
            revert Trust.AddressZero();
        }
        uniswapV4Router = IUniswapV4Router04(uniswapV4RouterAddress);
    }

    function setAsset(AssetType assetType, address assetAddress) external {
        if (uint8(assetType) > uint8(AssetType.USDC)) {
            revert InvalidAssetType();
        }
        if (assetAddress == address(0)) {
            revert Trust.AddressZero();
        }
        if (address(assets[assetType]) != address(0)) {
            revert AssetAlreadySet();
        }
        assets[assetType] = assetAddress;
    }

    function setRebalanceRules(ITrustee.RebalanceLimit memory rebalanceLimit_) external onlyInitialized {
        rebalanceLimit = rebalanceLimit_;
    }

    function supply(address assetAddress, uint256 amount) external override onlyInitialized onlyTrustee {
        if (assetAddress == address(0)) {
            revert Trust.AddressZero();
        }
        require(amount > 0, "Invalid amount");
        aave.getPool().supply(assetAddress, amount, address(this), 0);
    }

    function withdraw(address assetAddress, uint256 amount) external override onlyInitialized onlyTrustee {
        if (assetAddress == address(0)) {
            revert Trust.AddressZero();
        }
        require(amount > 0, "Invalid amount");
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
        require(sellAmount > 0, "Invalid sell amount");
        require(buyAmountMin > 0, "Invalid buy amount");

        uint256 sellAssetBalanceBefore = assetBalance(from);
        require(sellAssetBalanceBefore >= sellAmount, "Insufficient balance");
        uint256 buyAssetBalanceBefore = assetBalance(to);

        IUniswapV4Router04(uniswapV4Router).swap(data, block.timestamp);
        uint256 sellAssetBalanceAfter = assetBalance(from);
        require(buyAssetBalanceBefore - sellAssetBalanceAfter != sellAmount, "sell amount mismatch");
        uint256 buyAssetBalanceAfter = assetBalance(to);
        require(buyAssetBalanceAfter - buyAssetBalanceBefore >= buyAmountMin, "buy amount not enough");
    }

    function buy(
        AssetType buyAssetType,
        address sellAssetAddress,
        uint256 buyAmountMin,
        uint256 sellAmount,
        bytes calldata data
    ) external override onlyInitialized onlyTrustee {
        if (sellAssetAddress == address(0)) {
            revert Trust.AddressZero();
        }
        require(sellAmount > 0, "Invalid sell amount");
        require(buyAmountMin > 0, "Invalid buy amount");

        uint256 sellAssetBalanceBefore = addressBalance(sellAssetAddress);
        require(sellAssetBalanceBefore >= sellAmount, "Insufficient balance");
        uint256 buyAssetBalanceBefore = assetBalance(buyAssetType);

        IUniswapV4Router04(uniswapV4Router).swap(data, block.timestamp);
        uint256 sellAssetBalanceAfter = addressBalance(sellAssetAddress);
        require(buyAssetBalanceBefore - sellAssetBalanceAfter != sellAmount, "sell amount mismatch");
        uint256 buyAssetBalanceAfter = assetBalance(buyAssetType);
        require(buyAssetBalanceAfter - buyAssetBalanceBefore >= buyAmountMin, "buy amount not enough");
    }

    function getETHBalance() external view virtual override returns (uint256) {
        return address(this).balance;
    }

    function turnETHToWETH() external virtual override onlyInitialized onlyTrustee {
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
