// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1SubVaultBase} from "./BittyV1SubVaultBase.sol";
import {DeFiLogic} from "../logic/DeFiLogic.sol";
import {BittyStorage, SubVaultStorage} from "../logic/BittyStorage.sol";
import {
    IBittyV1SubVault,
    NotSubOwner,
    SubOwnerExpiryInPast,
    SubOwnerDeadlineRequired
} from "../interfaces/IBittyV1SubVault.sol";
import {GrantTooLong} from "../interfaces/IBittyV1DeFi.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IBittyV1Guard, ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {
    AddressZero,
    AmountIsZero,
    InvalidAsset,
    NotTrustedForwarder,
    InvalidRelayedCalldata,
    GasBudgetExceeded,
    GasBudgetTooHigh,
    FeeExceedsPerOpCap,
    ArrayLengthMismatch
} from "../interfaces/IBittyV1Vault.sol";
import {
    BITTY_GUARD,
    BITTY_FEE_COLLECTOR,
    SYSTEM_DAILY_MAX_GAS_BUDGET,
    SYSTEM_MAX_FEE_PER_OP,
    MAX_DURATION
} from "../logic/Constants.sol";

/**
 * @title BittyV1SubVault
 * @notice An isolated, DeFi-only account owned by a delegate. Its full DeFi surface is reached through
 *         the fallback → shared {BittyV1VaultDeFiFacet}; the only asset exits are {recall} (parent-forced)
 *         and {returnToVault} (sub-owner voluntary) — both to the parent, never to an outside address.
 *         Gasless is sub-funded: the parent flips the switch, the sub owner tunes the limits, the sub
 *         pays its own relayer fee.
 */
contract BittyV1SubVault is BittyV1SubVaultBase, IBittyV1SubVault {
    using SafeERC20 for IERC20;

    address public immutable DEFI_FACET;

    error SubGaslessDisabled();

    constructor(address defiFacet) {
        DEFI_FACET = defiFacet;
        _disableInitializers();
    }

    function initialize(address vault_, address subOwner_, bool allowlistEnabled, uint64 expiresAt)
        external
        override
        initializer
    {
        if (vault_ == address(0) || subOwner_ == address(0)) revert AddressZero();
        SubVaultStorage storage $ = BittyStorage.subVault();
        $.vault = vault_;
        _setExpiry($, expiresAt);
        __Ownable_init(subOwner_);
        DeFiLogic.initialize(allowlistEnabled);
    }

    function _setExpiry(SubVaultStorage storage $, uint64 expiresAt) private {
        if (expiresAt == 0) revert SubOwnerDeadlineRequired();
        if (expiresAt <= block.timestamp) revert SubOwnerExpiryInPast();
        if (expiresAt > block.timestamp + MAX_DURATION) revert GrantTooLong();
        $.subOwnerExpiresAt = expiresAt;
    }

    function expireSubOwnerNow() external override onlyParent {
        BittyStorage.subVault().subOwnerExpiresAt = uint64(block.timestamp);
    }

    function vault() public view override returns (address) {
        return BittyStorage.subVault().vault;
    }

    function subOwner() external view override returns (address) {
        return owner();
    }

    function subOwnerExpiresAt() external view override returns (uint64) {
        return BittyStorage.subVault().subOwnerExpiresAt;
    }

    function setSubOwner(address newOwner, uint64 expiresAt) external override onlyParent {
        if (newOwner == address(0)) revert AddressZero();
        _setExpiry(BittyStorage.subVault(), expiresAt);
        _transferOwnership(newOwner);
    }

    function setSubOwnerExpiry(uint64 expiresAt) external override onlyParent {
        _setExpiry(BittyStorage.subVault(), expiresAt);
    }

    function setGaslessEnabled(bool enabled) external override onlyParent {
        BittyStorage.subVault().gaslessEnabled = enabled;
    }

    function recall(address[] calldata assets, uint256[] calldata amounts) external override onlyParent {
        _toParent(assets, amounts);
    }

    function returnToVault(address[] calldata assets, uint256[] calldata amounts) external override {
        if (!_grantLapsed() && _msgSender() != owner()) revert NotSubOwner();
        _toParent(assets, amounts);
    }

    function _toParent(address[] calldata assets, uint256[] calldata amounts) private {
        if (assets.length != amounts.length) revert ArrayLengthMismatch();
        address parent = BittyStorage.subVault().vault;
        for (uint256 i; i < assets.length; ++i) {
            if (amounts[i] == 0) continue;
            IERC20(assets[i]).safeTransfer(parent, amounts[i]);
        }
    }

    function _grantLapsed() private view returns (bool) {
        uint64 expiresAt = BittyStorage.subVault().subOwnerExpiresAt;
        return expiresAt != 0 && block.timestamp >= expiresAt;
    }

    function setGasless(uint64 dailyLimit, uint64 maxFeePerOp) external {
        if (_msgSender() != owner()) revert NotSubOwner();
        if (dailyLimit > SYSTEM_DAILY_MAX_GAS_BUDGET) revert GasBudgetTooHigh();
        if (maxFeePerOp > SYSTEM_MAX_FEE_PER_OP) revert FeeExceedsPerOpCap();
        SubVaultStorage storage $ = BittyStorage.subVault();
        $.gasDailyLimit = dailyLimit;
        $.maxFeePerOp = maxFeePerOp;
    }

    function payRelayerFee(address asset, uint256 amount) external {
        if (msg.sender != trustedForwarder()) revert NotTrustedForwarder();
        SubVaultStorage storage $ = BittyStorage.subVault();
        if (!$.gaslessEnabled) revert SubGaslessDisabled();
        if (amount == 0) revert AmountIsZero();
        if (IBittyV1Guard(BITTY_GUARD).assetCategory(asset) != ASSET_STABLE_COIN) revert InvalidAsset();

        uint64 dailyLimit = $.gasDailyLimit == 0 ? SYSTEM_DAILY_MAX_GAS_BUDGET : $.gasDailyLimit;
        uint64 feeCap = $.maxFeePerOp == 0 ? SYSTEM_MAX_FEE_PER_OP : $.maxFeePerOp;
        uint256 value = Math.mulDiv(amount, 1e18, 10 ** IERC20Metadata(asset).decimals(), Math.Rounding.Ceil);
        if (value > uint256(feeCap) * 1e18) revert FeeExceedsPerOpCap();

        uint64 today = uint64(block.timestamp / 1 days);
        uint256 spent = ($.gasBudgetDay == today ? uint256($.gasSpentToday) : 0) + value;
        if (spent > uint256(dailyLimit) * 1e18) revert GasBudgetExceeded();
        $.gasBudgetDay = today;
        $.gasSpentToday = uint96(spent);
        IERC20(asset).safeTransfer(BITTY_FEE_COLLECTOR, amount);
    }

    function gaslessConfig() external view returns (bool enabled, uint256 dailyLimit, uint256 maxFeePerOp) {
        SubVaultStorage storage $ = BittyStorage.subVault();
        return (
            $.gaslessEnabled,
            $.gasDailyLimit == 0 ? SYSTEM_DAILY_MAX_GAS_BUDGET : $.gasDailyLimit,
            $.maxFeePerOp == 0 ? SYSTEM_MAX_FEE_PER_OP : $.maxFeePerOp
        );
    }

    function gasBudgetRemaining() external view returns (uint256) {
        SubVaultStorage storage $ = BittyStorage.subVault();
        if (!$.gaslessEnabled) return 0;
        uint64 dl = $.gasDailyLimit == 0 ? SYSTEM_DAILY_MAX_GAS_BUDGET : $.gasDailyLimit;
        uint256 limit = uint256(dl) * 1e18;
        if ($.gasBudgetDay != uint64(block.timestamp / 1 days)) return limit;
        uint256 spent = $.gasSpentToday;
        return spent >= limit ? 0 : limit - spent;
    }

    fallback() external payable {
        if (msg.data.length < 24 && msg.sender == trustedForwarder()) revert InvalidRelayedCalldata();
        address facet = DEFI_FACET;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}
