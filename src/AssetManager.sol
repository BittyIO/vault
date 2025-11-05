// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {IAssetManager} from "./interfaces/IAssetManager.sol";
import {ITrustee} from "./interfaces/ITrustee.sol";
import {Trust} from "./Trust.sol";
import {IERC20} from "./common/IERC20.sol";

interface IWETH {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
}

abstract contract AssetManager is IAssetManager {
    error WETHNotSet();
    error WETHAlreadySet();
    error USDTNotSet();
    error USDTAlreadySet();
    error USDCNotSet();
    error USDCAlreadySet();

    IWETH public weth;
    IERC20 internal _usdt;
    IERC20 internal _usdc;

    ITrustee.RebalanceLimit public rebalanceLimit;

    modifier onlyInitialized() virtual;

    function setWETH(address wethAddress) external virtual {
        if (wethAddress == address(0)) {
            revert Trust.AddressZero();
        }
        if (address(weth) != address(0)) {
            revert WETHAlreadySet();
        }
        weth = IWETH(wethAddress);
    }

    function setUSDT(address usdtAddress) external virtual {
        if (usdtAddress == address(0)) {
            revert Trust.AddressZero();
        }
        if (address(_usdt) != address(0)) {
            revert USDTAlreadySet();
        }
        _usdt = IERC20(usdtAddress);
    }

    function setUSDC(address usdcAddress) external virtual {
        if (usdcAddress == address(0)) {
            revert Trust.AddressZero();
        }
        if (address(_usdc) != address(0)) {
            revert USDCAlreadySet();
        }
        _usdc = IERC20(usdcAddress);
    }

    function setRebalanceRules(ITrustee.RebalanceLimit memory rebalanceLimit_)
        external
        virtual
        onlyInitialized
        onlyTrustee
    {
        rebalanceLimit = rebalanceLimit_;
    }

    function setRebalanceRulesInternal(ITrustee.RebalanceLimit memory rebalanceLimit_) internal {
        rebalanceLimit = rebalanceLimit_;
    }

    modifier onlyTrustee() virtual;

    function supply(address assetAddress, uint256 amount) external virtual override onlyInitialized onlyTrustee {
        if (assetAddress == address(0)) {
            revert Trust.AddressZero();
        }
        require(amount > 0, "Invalid amount");
    }

    function withdraw(address assetAddress, uint256 amount) external virtual override onlyInitialized onlyTrustee {
        if (assetAddress == address(0)) {
            revert Trust.AddressZero();
        }
        require(amount > 0, "Invalid amount");
    }

    function rebalance(
        AssetType, /* from */
        AssetType, /* to */
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 slippage
    ) external virtual override onlyInitialized onlyTrustee {
        require(sellAmount > 0, "Invalid sell amount");
        require(buyAmount > 0, "Invalid buy amount");
        require(slippage <= 10000, "Slippage too high");
    }

    function buy(
        AssetType, /* buyAssetType */
        address sellAssetAddress,
        uint256 buyAmount,
        uint256 sellAmount,
        uint256 slippage
    ) external virtual override onlyInitialized onlyTrustee {
        if (sellAssetAddress == address(0)) {
            revert Trust.AddressZero();
        }
        require(buyAmount > 0, "Invalid buy amount");
        require(sellAmount > 0, "Invalid sell amount");
        require(slippage <= 10000, "Slippage too high");
    }

    function getETHBalance() external view virtual override returns (uint256) {
        return address(this).balance;
    }

    function turnETHToWETH() external virtual override onlyInitialized onlyTrustee {
        if (address(weth) == address(0)) {
            revert WETHNotSet();
        }
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            weth.deposit{value: ethBalance}();
        }
    }

    function getWETHBalance() external view virtual override returns (uint256) {
        if (address(weth) == address(0)) {
            revert WETHNotSet();
        }
        return weth.balanceOf(address(this));
    }

    receive() external payable {}

    fallback() external payable {}
}
