// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {ILendingProvider} from "../interfaces/IAssetManager.sol";
import {IAaveV3, IAavePool} from "../libs/Aave.sol";
import {IPoolDataProvider} from "../libs/Aave.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

contract AaveProvider is ILendingProvider, Ownable, Initializable {
    using SafeERC20 for IERC20;
    address public immutable aaveV3;
    address public immutable poolDataProvider;

    constructor(address aaveV3_, address poolDataProvider_) {
        aaveV3 = aaveV3_;
        poolDataProvider = poolDataProvider_;
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    function supply(address asset, uint256 amount) external payable override onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IAavePool pool = IAaveV3(aaveV3).getPool();
        IERC20(asset).safeIncreaseAllowance(address(pool), amount);
        pool.supply(asset, amount, address(this), 0);
    }

    function withdraw(address asset, uint256 amount) external override onlyOwner {
        IAaveV3(aaveV3).getPool().withdraw(asset, amount, address(this));
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function getBalance(address asset) external view override returns (uint256) {
        (uint256 currentATokenBalance,,,,,,,,) =
            IPoolDataProvider(poolDataProvider).getUserReserveData(asset, address(this));
        return currentATokenBalance;
    }
}
