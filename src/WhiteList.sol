// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IWhiteList} from "./interfaces/IWhiteList.sol";

contract WhiteList is IWhiteList, Initializable, Ownable {
    mapping(address => bool) public whiteListedAssets;
    mapping(address => bool) public whiteListedStableCoins;
    mapping(address => bool) public whiteListedYieldProviders;
    mapping(address => bool) public deprecatedYieldProviders;
    mapping(address => bool) public whiteListedSwapProviders;

    constructor() {
        transferOwnership(tx.origin);
    }

    function addAssets(address[] memory assetAddresses) external override onlyOwner {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (assetAddresses[i] != address(0)) {
                whiteListedAssets[assetAddresses[i]] = true;
            }
        }
    }

    function removeAssets(address[] memory assetAddresses) external override onlyOwner {
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            if (assetAddresses[i] != address(0)) {
                whiteListedAssets[assetAddresses[i]] = false;
            }
        }
    }

    function isAssetWhiteListed(address assetAddress) external view override returns (bool) {
        return whiteListedAssets[assetAddress];
    }

    function addStableCoins(address[] memory stableCoinAddresses) external override onlyOwner {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (stableCoinAddresses[i] != address(0)) {
                whiteListedStableCoins[stableCoinAddresses[i]] = true;
            }
        }
    }

    function removeStableCoins(address[] memory stableCoinAddresses) external override onlyOwner {
        for (uint256 i = 0; i < stableCoinAddresses.length; i++) {
            if (stableCoinAddresses[i] != address(0)) {
                whiteListedStableCoins[stableCoinAddresses[i]] = false;
            }
        }
    }

    function isStableCoinWhiteListed(address stableCoinAddress) external view override returns (bool) {
        return whiteListedStableCoins[stableCoinAddress];
    }

    function addYieldProviders(address[] memory yieldProviderAddresses) external override onlyOwner {
        for (uint256 i = 0; i < yieldProviderAddresses.length; i++) {
            if (yieldProviderAddresses[i] != address(0)) {
                whiteListedYieldProviders[yieldProviderAddresses[i]] = true;
                deprecatedYieldProviders[yieldProviderAddresses[i]] = false;
            }
        }
    }

    function deprecateYieldProviders(address[] memory yieldProviderAddresses) external override onlyOwner {
        for (uint256 i = 0; i < yieldProviderAddresses.length; i++) {
            if (yieldProviderAddresses[i] != address(0)) {
                whiteListedYieldProviders[yieldProviderAddresses[i]] = false;
                deprecatedYieldProviders[yieldProviderAddresses[i]] = true;
            }
        }
    }

    function isYieldProviderWhiteListed(address yieldProviderAddress) external view override returns (bool) {
        return whiteListedYieldProviders[yieldProviderAddress];
    }

    function isYieldProviderDeprecated(address yieldProviderAddress) external view override returns (bool) {
        return deprecatedYieldProviders[yieldProviderAddress];
    }

    function addSwapProviders(address[] memory swapProviderAddresses) external override onlyOwner {
        for (uint256 i = 0; i < swapProviderAddresses.length; i++) {
            if (swapProviderAddresses[i] != address(0)) {
                whiteListedSwapProviders[swapProviderAddresses[i]] = true;
            }
        }
    }

    function removeSwapProviders(address[] memory swapProviderAddresses) external override onlyOwner {
        for (uint256 i = 0; i < swapProviderAddresses.length; i++) {
            if (swapProviderAddresses[i] != address(0)) {
                whiteListedSwapProviders[swapProviderAddresses[i]] = false;
            }
        }
    }

    function isSwapProviderWhiteListed(address swapProviderAddress) external view override returns (bool) {
        return whiteListedSwapProviders[swapProviderAddress];
    }
}
