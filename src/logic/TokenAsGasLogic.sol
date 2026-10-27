// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    NotInitialized,
    AmountIsZero,
    InvalidAsset,
    InsufficientBalance,
    FeeExceedsPerOpCap,
    GasBudgetExceeded,
    GasBudgetTooHigh
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../interfaces/IBittyV1Owner.sol";
import {IBittyV1Guard, ASSET_STABLE_COIN, PriceFeed} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BittyStorage, VaultStorage} from "./BittyStorage.sol";
import {TimelockLib} from "./TimelockLib.sol";
import {RiskLogic} from "./RiskLogic.sol";
import {PriceLib} from "./PriceLib.sol";
import {
    BITTY_GUARD,
    BITTY_FEE_COLLECTOR,
    SENTINEL,
    SYSTEM_DAILY_MAX_GAS_BUDGET,
    SYSTEM_MAX_FEE_PER_OP
} from "./Constants.sol";

/**
 * @title TokenAsGasLogic
 * @notice The main vault's relayed-gas surface: the per-UTC-day USD budget the vault will pay a trusted
 *         forwarder from, its config, the one-time activation fee, and the per-relay charge. Fees are
 *         paid in a stablecoin (a dollar) or the vault's WETH ({VaultStorage-gasWrapped}, valued off the
 *         guard's Chainlink feed), so the same daily budget and per-op cap bound both.
 *         Split out of {PaymentLogic}; operates on the same ERC-7201 {VaultStorage}.
 */
library TokenAsGasLogic {
    using SafeERC20 for IERC20;

    function _onlyInitialized(VaultStorage storage vaultStorage) private view {
        if (!vaultStorage.isInitialized) revert NotInitialized();
    }

    function _dailyLimit(VaultStorage storage vaultStorage) private view returns (uint64) {
        if (vaultStorage.tokenAsGasDisabled) return 0;
        uint64 owned = TimelockLib.effective(vaultStorage.gasBudgetDaily);
        return owned == 0 ? SYSTEM_DAILY_MAX_GAS_BUDGET : owned;
    }

    function _feePerOpCap(VaultStorage storage vaultStorage) private view returns (uint64) {
        uint64 owned = TimelockLib.effective(vaultStorage.maxFeePerOp);
        return owned == 0 ? SYSTEM_MAX_FEE_PER_OP : owned;
    }

    function disableTokenAsGas() external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        _onlyInitialized(vaultStorage);
        vaultStorage.tokenAsGasDisabled = true;
        // Off is the tightest the budget can be, so a raise still waiting out the timelock goes with it;
        // otherwise it would land unseen the moment the owner turned token-as-gas back on.
        TimelockLib.cancelPending(vaultStorage.gasBudgetDaily);
        TimelockLib.cancelPending(vaultStorage.maxFeePerOp);
        emit IBittyV1Owner.TokenAsGasSet(false, new address[](0), 0, 0);
    }

    function setTokenAsGas(address[] calldata assets, uint64 dailyLimit, uint64 maxFeePerOp) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        _onlyInitialized(vaultStorage);
        if (dailyLimit > SYSTEM_DAILY_MAX_GAS_BUDGET) revert GasBudgetTooHigh();
        if (maxFeePerOp > SYSTEM_MAX_FEE_PER_OP) revert FeeExceedsPerOpCap();

        mapping(address => address) storage allowed = vaultStorage.tokenAsGasAssets;
        address entry = allowed[SENTINEL];
        while (entry != SENTINEL && entry != address(0)) {
            address next = allowed[entry];
            allowed[entry] = address(0);
            entry = next;
        }
        allowed[SENTINEL] = SENTINEL;

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            if (!_gasEligible(vaultStorage, asset)) revert InvalidAsset();
            if (asset == address(0) || asset == SENTINEL || allowed[asset] != address(0)) continue;
            allowed[asset] = allowed[SENTINEL];
            allowed[SENTINEL] = asset;
        }

        vaultStorage.tokenAsGasDisabled = false;
        uint64 timelock = RiskLogic.effectiveTimelock(vaultStorage.riskConfig);
        TimelockLib.setGasBudget(vaultStorage.gasBudgetDaily, dailyLimit, timelock);
        TimelockLib.setGasBudget(vaultStorage.maxFeePerOp, maxFeePerOp, timelock);
        emit IBittyV1Owner.TokenAsGasSet(true, assets, dailyLimit, maxFeePerOp);
    }

    function getTokenAsGasAssets() external view returns (address[] memory) {
        mapping(address => address) storage allowed = BittyStorage.vault().tokenAsGasAssets;
        uint256 n;
        for (address a = allowed[SENTINEL]; a != SENTINEL && a != address(0); a = allowed[a]) {
            n++;
        }
        address[] memory out = new address[](n);
        uint256 i;
        for (address a = allowed[SENTINEL]; a != SENTINEL && a != address(0); a = allowed[a]) {
            out[i++] = a;
        }
        return out;
    }

    function maxFeePerOpValue() external view returns (uint256) {
        return _feePerOpCap(BittyStorage.vault());
    }

    function gasBudgetDailyLimit() external view returns (uint256) {
        return _dailyLimit(BittyStorage.vault());
    }

    function gasBudgetRemaining() external view returns (uint256) {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        uint256 limit = uint256(_dailyLimit(vaultStorage)) * 1e18;
        if (vaultStorage.gasBudgetDay != uint64(block.timestamp / 1 days)) return limit;
        uint256 spent = vaultStorage.gasSpentToday;
        return spent >= limit ? 0 : limit - spent;
    }

    function relayerFeeValue(address asset, uint256 amount) external view returns (uint256) {
        return _feeValue(BittyStorage.vault(), asset, amount);
    }

    function payActivationFee(address asset, uint256 amount) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        _onlyInitialized(vaultStorage);
        if (!_gasEligible(vaultStorage, asset)) revert InvalidAsset();
        uint256 value = _feeValue(vaultStorage, asset, amount);
        if (value > uint256(SYSTEM_MAX_FEE_PER_OP) * 1e18) revert FeeExceedsPerOpCap();
        if (IERC20(asset).balanceOf(address(this)) < amount) revert InsufficientBalance();
        IERC20(asset).safeTransfer(BITTY_FEE_COLLECTOR, amount);
        emit IBittyV1Owner.ActivationFeePaid(asset, amount);
    }

    function _gasEligible(VaultStorage storage vaultStorage, address asset) private view returns (bool) {
        return
            asset == vaultStorage.gasWrapped
                || (IBittyV1Guard(BITTY_GUARD).assetCategory(asset) & ASSET_STABLE_COIN) != 0;
    }

    function _feeValue(VaultStorage storage vaultStorage, address asset, uint256 amount)
        private
        view
        returns (uint256)
    {
        if (asset != vaultStorage.gasWrapped) {
            return Math.mulDiv(amount, 1e18, 10 ** IERC20Metadata(asset).decimals(), Math.Rounding.Ceil);
        }
        IBittyV1Guard guard = IBittyV1Guard(BITTY_GUARD);
        PriceLib.requireSequencerUp(guard.sequencerUptimeFeed());
        PriceFeed memory feed = guard.priceFeed(asset);
        PriceFeed memory quoteFeed;
        if (feed.hasQuote) quoteFeed = guard.priceFeed(feed.quote);
        return PriceLib.usdValue(asset, 0, amount, Math.Rounding.Ceil, feed, quoteFeed);
    }

    function _tokenAsGasAssetAllowed(VaultStorage storage vaultStorage, address asset) private view returns (bool) {
        if (asset == address(0) || asset == SENTINEL) return false;
        if (!_gasEligible(vaultStorage, asset)) return false;
        address head = vaultStorage.tokenAsGasAssets[SENTINEL];
        if (head == address(0) || head == SENTINEL) {
            return true;
        }
        return vaultStorage.tokenAsGasAssets[asset] != address(0);
    }

    function payRelayerFee(address asset, uint256 amount) external {
        VaultStorage storage vaultStorage = BittyStorage.vault();
        _onlyInitialized(vaultStorage);
        if (amount == 0) revert AmountIsZero();
        if (!_tokenAsGasAssetAllowed(vaultStorage, asset)) revert InvalidAsset();

        uint256 value = _feeValue(vaultStorage, asset, amount);
        if (value > uint256(_feePerOpCap(vaultStorage)) * 1e18) revert FeeExceedsPerOpCap();

        uint64 today = uint64(block.timestamp / 1 days);
        uint256 spent = (vaultStorage.gasBudgetDay == today ? uint256(vaultStorage.gasSpentToday) : 0) + value;
        uint256 limit = uint256(_dailyLimit(vaultStorage)) * 1e18;
        if (spent > limit) revert GasBudgetExceeded();

        vaultStorage.gasBudgetDay = today;
        vaultStorage.gasSpentToday = uint96(spent);
        IERC20(asset).safeTransfer(BITTY_FEE_COLLECTOR, amount);
        emit IBittyV1Owner.RelayerFeePaid(asset, amount, spent, limit - spent);
    }
}
