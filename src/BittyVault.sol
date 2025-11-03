// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {ITrustee} from "./interfaces/ITrustee.sol";
import {IGrantor} from "./interfaces/IGrantor.sol";
import {AssetManager} from "./AssetManager.sol";
import {Trust} from "./Trust.sol";
import {IERC20} from "./common/IERC20.sol";

/**
 * @title BittyVault
 * @notice Unified vault contract that combines Asset Management and Trust Management
 * @dev
 * This contract inherits from both AssetManager and Trust, providing a single interface
 * for both asset management operations (supply, withdraw, rebalance, etc.) and trust
 * management operations (initialize, revoke, set beneficiaries, etc.).
 *
 * Users can use this contract for asset management only, trust management only, or both.
 * The contract address remains the same regardless of which functions are used.
 * All asset management functions are defined in AssetManager.sol
 * All trust management functions are defined in Trust.sol (which implements ITrust)
 * This contract only handles:
 * 1. Resolving inheritance conflicts (modifiers, abstract functions)
 * 2. Bridging between the two modules (usdt/usdc functions for Trust.getMoney)
 */
contract BittyVault is AssetManager, Trust {
    /**
     * @notice Override to resolve conflict between AssetManager and Trust onlyInitialized modifiers
     */
    modifier onlyInitialized() override(AssetManager, Trust) {
        require(isInitialized, "Trust not initialized");
        _;
    }

    /**
     * @notice Override to resolve conflict between AssetManager and Trust onlyTrustee modifiers
     */
    modifier onlyTrustee() override(AssetManager, Trust) {
        require(msg.sender == trustee, "Only trustee");
        _;
    }

    /**
     * @notice Returns USDT contract address
     * @dev Required by Trust.getMoney() to access stablecoin contracts
     * @return IERC20 The USDT contract interface
     */
    function usdt() external view override returns (IERC20) {
        return _usdt;
    }

    /**
     * @notice Returns USDC contract address
     * @dev Required by Trust.getMoney() to access stablecoin contracts
     * @return IERC20 The USDC contract interface
     */
    function usdc() external view override returns (IERC20) {
        return _usdc;
    }

    /**
     * @notice Set rebalance rules
     * @dev Override to resolve conflict between AssetManager and IGrantor interfaces
     * @param rebalanceLimit_ The rebalance limit configuration
     */
    function setRebalanceRules(ITrustee.RebalanceLimit memory rebalanceLimit_)
        external
        override(AssetManager, IGrantor)
        onlyInitialized
        onlyTrustee
    {
        rebalanceLimit = rebalanceLimit_;
    }

    // All asset management functions are inherited from AssetManager:
    // - setWETH, setUSDT, setUSDC
    // - supply, withdraw, rebalance, buy
    // - turnETHToWETH, getETHBalance, getWETHBalance
    // - setRebalanceRules

    // All trust management functions are inherited from Trust:
    // - initialize, initaialize (multiple overloads)
    // - revoke, setToIrrevocable
    // - ping, setAutoIrrevocableAfterNoPing
    // - setGrantor, setTrustee, setBeneficiary
    // - setBeneficiarySettings, getMoney
    // - changeBeneficiaryAddress, changeTrusteeAddress
    // - setStartDistributionTimestamp, distributionStarted
    // - upgrade
}
