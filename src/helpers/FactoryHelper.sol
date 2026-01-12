// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IWhiteList} from "../interfaces/IWhiteList.sol";
import {NotWhiteListed} from "../interfaces/Errors.sol";

library FactoryHelper {
    /**
     * @notice Check if all addresses are whitelisted
     * @dev Validates assets, stablecoins, yield providers, and swap providers
     */
    function checkWhiteList(
        IWhiteList whiteList,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory swapProviders
    ) public view {
        uint256 i;
        for (i = 0; i < assetAddresses.length; i++) {
            if (!whiteList.isAssetWhiteListed(assetAddresses[i])) revert NotWhiteListed();
        }
        for (i = 0; i < stableCoinAddresses.length; i++) {
            if (!whiteList.isStableCoinWhiteListed(stableCoinAddresses[i])) revert NotWhiteListed();
        }
        for (i = 0; i < lendingProviders.length; i++) {
            if (!whiteList.isLendingProviderWhiteListed(lendingProviders[i])) revert NotWhiteListed();
        }
        for (i = 0; i < stakingProviders.length; i++) {
            if (!whiteList.isStakingProviderWhiteListed(stakingProviders[i])) revert NotWhiteListed();
        }
        for (i = 0; i < swapProviders.length; i++) {
            if (!whiteList.isSwapProviderWhiteListed(swapProviders[i])) revert NotWhiteListed();
        }
    }
}

