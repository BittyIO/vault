// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    NotInitialized,
    InsufficientBalance,
    TransferFailed,
    ReentrantCall,
    ProtectionPeriodNotEnded,
    IBittyV1Vault
} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {BittyStorage, VaultStorage, DeFiStorage} from "./BittyStorage.sol";
import {BITTY_GUARD, STABLE_COIN_CATEGORY} from "./Constants.sol";

/**
 * @title PaymentCore
 * @notice Primitives shared by {PaymentLogic} (sends), {ScheduledPaymentLogic}, and {WhitelistLogic}:
 *         the reentrancy-guarded native/ERC-20 payout, the stablecoin check, the protection-window
 *         helpers, and the locked-immutable test. Internal, so each consumer inlines what it uses.
 */
library PaymentCore {
    using SafeERC20 for IERC20;

    // Transient native-ETH payout reentrancy lock — keccak256("bitty.transient.vault.payingEth").
    //
    // TSTORE, not SSTORE: this lives for one transaction and is gone. So unlike the ERC-7201 roots in
    // {BittyStorage}, the id here binds nothing across an upgrade — there is never persisted data at
    // this slot for a later implementation to lose track of. It is versionless for consistency with
    // those, not because it has to be.
    bytes32 private constant _PAYING_ETH_SLOT = 0x71073f41b1fbea3b4b767dfde0481e6b3581a828457e188fce9c91ccd560f31d;

    function onlyInitialized(VaultStorage storage vaultStorage) internal view {
        if (!vaultStorage.isInitialized) revert NotInitialized();
    }

    function stableCoinAllowed(address asset) internal view returns (bool) {
        if (IBittyV1Guard(BITTY_GUARD).assetCategory(asset) != STABLE_COIN_CATEGORY) return false;
        DeFiStorage storage d = BittyStorage.defi();
        if (d.allowlistEnabled && !(d.allowlistDisableAt != 0 && block.timestamp >= d.allowlistDisableAt)) {
            if (!d.assets[asset]) return false;
        }
        return true;
    }

    function payOut(VaultStorage storage vaultStorage, address asset, uint256 amount, address to) internal {
        if (amount == 0) return;
        if (asset == address(0)) {
            bool locked;
            assembly ("memory-safe") {
                locked := tload(_PAYING_ETH_SLOT)
            }
            if (locked) revert ReentrantCall();
            assembly ("memory-safe") {
                tstore(_PAYING_ETH_SLOT, 1)
            }
            WETH(payable(vaultStorage.weth)).withdraw(amount);
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
            assembly ("memory-safe") {
                tstore(_PAYING_ETH_SLOT, 0)
            }
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function transferMoney(
        VaultStorage storage vaultStorage,
        address erc20Address,
        uint256 amount,
        address recipient,
        bool payWithInsufficientBalance
    ) internal returns (uint256 paidAmount) {
        address balanceToken = erc20Address == address(0) ? vaultStorage.weth : erc20Address;
        uint256 balance = IERC20(balanceToken).balanceOf(address(this));
        if (!payWithInsufficientBalance && balance < amount) revert InsufficientBalance();
        paidAmount = balance < amount ? balance : amount;
        payOut(vaultStorage, erc20Address, paidAmount, recipient);
    }

    function protectionDeadline(uint256 protection) internal view returns (uint256) {
        return protection == 0 ? 0 : block.timestamp + protection;
    }

    function immutableLockDeadlineFromWindow(uint64 window) internal view returns (uint256) {
        return block.timestamp + window;
    }

    function requireProtectionElapsed(uint256 effectiveAt) internal view {
        if (block.timestamp < effectiveAt) revert ProtectionPeriodNotEnded();
    }

    function isLockedImmutable(VaultStorage storage vaultStorage, uint256 id) internal view returns (bool) {
        IBittyV1Vault.ScheduledPayment storage p = vaultStorage.scheduledPayments[id];
        return p.isImmutable && p.remainingPaymentCount > 0
            && vaultStorage.scheduledPaymentPendingProposer[id] == address(0)
            && block.timestamp >= vaultStorage.scheduledPaymentEffectiveAt[id];
    }
}
