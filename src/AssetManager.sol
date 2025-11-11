// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {ITrustee} from "./interfaces/ITrustee.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IAaveV3} from "./libs/Aave.sol";
import {IUniswapV4Router04} from "./libs/Uniswap.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AddressZero,
    AmountIsZero,
    WETHNotSet,
    RebalanceInMinimalTime,
    InsufficientBalance,
    SellAmountMismatch,
    BuyAmountNotEnough,
    MinimalWBTCBalanceLimit,
    MinimalWETHBalanceLimit,
    MinimalStableCoinBalanceLimit
} from "./interfaces/Errors.sol";

interface IWETH {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
}

abstract contract AssetManager is Initializable {
    enum AssetType {
        WBTC,
        WETH,
        USDT,
        USDC
    }

    struct RebalanceLimit {
        uint256 minimalWBTCBalance;
        uint256 minimalWETHBalance;
        uint256 minimalStableCoinBalance;
        uint256 minimalTimestampBetweenRebalances;
        uint256 maxRebalancePercentage;
    }

    using SafeERC20 for IERC20;
    mapping(AssetType => address) public assets;
    // only WETH and WBTC rebalance will be recorded
    mapping(AssetType => uint256) public lastRebalances;
    RebalanceLimit public rebalanceLimit;
    IAaveV3 public aave;
    IUniswapV4Router04 public uniswapV4Router;

    modifier _onlyInitialized() {
        InitializableStorage storage $;
        bytes32 slot = _initializableStorageSlot();
        assembly {
            $.slot := slot
        }
        if ($._initialized == 0) {
            revert InvalidInitialization();
        }
        _;
    }

    function initialize(
        address wethAddress,
        address wbtcAddress,
        address usdtAddress,
        address usdcAddress,
        address aaveV3Address,
        address uniswapV4RouterAddress
    ) internal {
        if (wethAddress != address(0)) {
            assets[AssetType.WETH] = wethAddress;
        }
        if (wbtcAddress != address(0)) {
            assets[AssetType.WBTC] = wbtcAddress;
        }
        if (usdtAddress != address(0)) {
            assets[AssetType.USDT] = usdtAddress;
        }
        if (usdcAddress != address(0)) {
            assets[AssetType.USDC] = usdcAddress;
        }
        if (aaveV3Address != address(0)) {
            aave = IAaveV3(aaveV3Address);
        }
        if (uniswapV4RouterAddress != address(0)) {
            uniswapV4Router = IUniswapV4Router04(uniswapV4RouterAddress);
        }
    }

    function _setRebalanceRules(RebalanceLimit memory rebalanceLimit_) internal _onlyInitialized {
        rebalanceLimit = rebalanceLimit_;
    }

    function _supply(address assetAddress, uint256 amount) internal _onlyInitialized {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        IERC20(assetAddress).safeIncreaseAllowance(address(aave.getPool()), amount);
        aave.getPool().supply(assetAddress, amount, address(this), 0);
    }

    function _withdraw(address assetAddress, uint256 amount) internal _onlyInitialized {
        if (assetAddress == address(0)) {
            revert AddressZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }
        aave.getPool().withdraw(assetAddress, amount, address(this));
    }

    function assetBalance(AssetType assetType) internal view returns (uint256) {
        return IERC20(assets[assetType]).balanceOf(address(this));
    }

    function addressBalance(address assetAddress) internal view returns (uint256) {
        if (assetAddress == address(0)) {
            return address(this).balance;
        }
        return IERC20(assetAddress).balanceOf(address(this));
    }

    function _rebalance(AssetType from, AssetType to, uint256 sellAmount, uint256 buyAmountMin, bytes calldata data)
        internal
        _onlyInitialized
    {
        if ((from == AssetType.WETH || to == AssetType.WETH) && lastRebalances[AssetType.WETH] != 0) {
            if (block.timestamp - lastRebalances[AssetType.WETH] < rebalanceLimit.minimalTimestampBetweenRebalances) {
                revert RebalanceInMinimalTime();
            }
        }
        if ((from == AssetType.WBTC || to == AssetType.WBTC) && lastRebalances[AssetType.WBTC] != 0) {
            if (block.timestamp - lastRebalances[AssetType.WBTC] < rebalanceLimit.minimalTimestampBetweenRebalances) {
                revert RebalanceInMinimalTime();
            }
        }
        if (from == AssetType.WBTC) {
            if (assetBalance(AssetType.WBTC) < (rebalanceLimit.minimalWBTCBalance + sellAmount)) {
                revert MinimalWBTCBalanceLimit();
            }
        } else if (from == AssetType.WETH) {
            if (assetBalance(AssetType.WETH) < (rebalanceLimit.minimalWETHBalance + sellAmount)) {
                revert MinimalWETHBalanceLimit();
            }
        } else if ((from == AssetType.USDT || from == AssetType.USDC) && (to == AssetType.WETH || to == AssetType.WBTC))
        {
            if (
                assetBalance(AssetType.USDT) + assetBalance(AssetType.USDC)
                    < (rebalanceLimit.minimalStableCoinBalance + sellAmount)
            ) {
                revert MinimalStableCoinBalanceLimit();
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

    //TODO: verify data is matching with the parms
    function _swap(
        address sellAssetAddress,
        uint256 sellAmount,
        AssetType toAssetType,
        uint256 buyAmountMin,
        bytes memory data
    ) internal _onlyInitialized {
        if (sellAmount == 0 || buyAmountMin == 0) {
            revert AmountIsZero();
        }
        uint256 sellAssetBalanceBefore = addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore < sellAmount) {
            revert InsufficientBalance();
        }
        uint256 buyAssetBalanceBefore = assetBalance(toAssetType);
        if (sellAssetAddress == address(0)) {
            IUniswapV4Router04(uniswapV4Router).swap{value: sellAmount}(data, block.timestamp);
        } else {
            IUniswapV4Router04(uniswapV4Router).swap(data, block.timestamp);
        }

        uint256 sellAssetBalanceAfter = addressBalance(sellAssetAddress);
        if (sellAssetBalanceBefore - sellAssetBalanceAfter != sellAmount) {
            revert SellAmountMismatch();
        }
        uint256 buyAssetBalanceAfter = assetBalance(toAssetType);
        if (buyAssetBalanceAfter - buyAssetBalanceBefore < buyAmountMin) {
            revert BuyAmountNotEnough();
        }
    }

    function getETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function _turnETHToWETH() internal _onlyInitialized {
        if (address(assets[AssetType.WETH]) == address(0)) {
            revert WETHNotSet();
        }
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            IWETH(assets[AssetType.WETH]).deposit{value: ethBalance}();
        }
    }

    function getWETHBalance() external view returns (uint256) {
        if (address(assets[AssetType.WETH]) == address(0)) {
            revert WETHNotSet();
        }
        return IWETH(assets[AssetType.WETH]).balanceOf(address(this));
    }

    receive() external payable {}

    fallback() external payable {}
}
