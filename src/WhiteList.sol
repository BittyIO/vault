// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IWhiteList} from "./interfaces/IWhiteList.sol";
import {SwapProviderShouldNotBeAllRemoved} from "./interfaces/IWhiteList.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

contract WhiteList is IWhiteList, Initializable, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(address => bool) public assets;
    mapping(address => bool) public stableCoins;
    mapping(address => bool) public lendingProviders;
    mapping(address => bool) public deprecatedLendingProviders;
    mapping(address => bool) public stakingProviders;
    mapping(address => bool) public deprecatedStakingProviders;

    EnumerableSet.AddressSet internal _swapProviders;

    constructor() {
        _transferOwnership(tx.origin);
    }

    function initialize(
        address[] memory assets_,
        address[] memory stableCoins_,
        address[] memory lendingProviders_,
        address[] memory stakingProviders_,
        address[] memory swapProviders_
    ) public initializer {
        _addAssets(assets_);
        _addStableCoins(stableCoins_);
        _addLendingProviders(lendingProviders_);
        _addStakingProviders(stakingProviders_);
        _addSwapProviders(swapProviders_);
    }

    function addAssets(address[] memory assetAddresses) external override onlyOwner {
        _addAssets(assetAddresses);
    }

    function _addAssets(address[] memory assetAddresses) internal {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (assetAddresses[i] != address(0)) {
                assets[assetAddresses[i]] = true;
            }
        }
    }

    function removeAssets(address[] memory assetAddresses) external override onlyOwner {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (assetAddresses[i] != address(0)) {
                assets[assetAddresses[i]] = false;
            }
        }
    }

    function isAssetWhiteListed(address assetAddress) external view override returns (bool) {
        return assets[assetAddress];
    }

    function addStableCoins(address[] memory stableCoinAddresses) external override onlyOwner {
        _addStableCoins(stableCoinAddresses);
    }

    function _addStableCoins(address[] memory stableCoinAddresses) internal {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (stableCoinAddresses[i] != address(0)) {
                stableCoins[stableCoinAddresses[i]] = true;
            }
        }
    }

    function removeStableCoins(address[] memory stableCoinAddresses) external override onlyOwner {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (stableCoinAddresses[i] != address(0)) {
                stableCoins[stableCoinAddresses[i]] = false;
            }
        }
    }

    function isStableCoinWhiteListed(address stableCoinAddress) external view override returns (bool) {
        return stableCoins[stableCoinAddress];
    }

    function addLendingProviders(address[] memory lendingProviderAddresses) external override onlyOwner {
        _addLendingProviders(lendingProviderAddresses);
    }

    function _addLendingProviders(address[] memory lendingProviderAddresses) internal {
        for (uint256 i = 0; i < lendingProviderAddresses.length; i++) {
            if (lendingProviderAddresses[i] != address(0)) {
                lendingProviders[lendingProviderAddresses[i]] = true;
                deprecatedLendingProviders[lendingProviderAddresses[i]] = false;
            }
        }
    }

    function deprecateLendingProviders(address[] memory lendingProviderAddresses) external override onlyOwner {
        for (uint256 i = 0; i < lendingProviderAddresses.length; i++) {
            if (lendingProviderAddresses[i] != address(0)) {
                lendingProviders[lendingProviderAddresses[i]] = false;
                deprecatedLendingProviders[lendingProviderAddresses[i]] = true;
            }
        }
    }

    function isLendingProviderWhiteListed(address lendingProviderAddress) external view override returns (bool) {
        return lendingProviders[lendingProviderAddress];
    }

    function isLendingProviderDeprecated(address lendingProviderAddress) external view override returns (bool) {
        return deprecatedLendingProviders[lendingProviderAddress];
    }

    function addStakingProviders(address[] memory stakingProviderAddresses) external override onlyOwner {
        _addStakingProviders(stakingProviderAddresses);
    }

    function _addStakingProviders(address[] memory stakingProviderAddresses) internal {
        for (uint256 i = 0; i < stakingProviderAddresses.length; i++) {
            if (stakingProviderAddresses[i] != address(0)) {
                stakingProviders[stakingProviderAddresses[i]] = true;
                deprecatedStakingProviders[stakingProviderAddresses[i]] = false;
            }
        }
    }

    function isStakingProviderWhiteListed(address stakingProviderAddress) external view override returns (bool) {
        return stakingProviders[stakingProviderAddress];
    }

    function isStakingProviderDeprecated(address stakingProviderAddress) external view override returns (bool) {
        return deprecatedStakingProviders[stakingProviderAddress];
    }

    function deprecateStakingProviders(address[] memory stakingProviderAddress) external override onlyOwner {
        for (uint256 i = 0; i < stakingProviderAddress.length; i++) {
            if (stakingProviderAddress[i] != address(0)) {
                stakingProviders[stakingProviderAddress[i]] = false;
                deprecatedStakingProviders[stakingProviderAddress[i]] = true;
            }
        }
    }

    function addSwapProviders(address[] memory swapProviderAddresses) external override onlyOwner {
        _addSwapProviders(swapProviderAddresses);
    }

    function _addSwapProviders(address[] memory swapProviderAddresses) internal {
        for (uint256 i = 0; i < swapProviderAddresses.length; i++) {
            if (swapProviderAddresses[i] != address(0)) {
                _swapProviders.add(swapProviderAddresses[i]);
            }
        }
    }

    function removeSwapProviders(address[] memory swapProviderAddresses) external override onlyOwner {
        for (uint256 i = 0; i < swapProviderAddresses.length; i++) {
            if (swapProviderAddresses[i] != address(0)) {
                _swapProviders.remove(swapProviderAddresses[i]);
            }
        }
        if (_swapProviders.length() == 0) {
            revert SwapProviderShouldNotBeAllRemoved();
        }
    }

    function isSwapProviderWhiteListed(address swapProviderAddress) external view override returns (bool) {
        return _swapProviders.contains(swapProviderAddress);
    }
}
