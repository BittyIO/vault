// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Guard, MarketTradeInfo} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {
    IBittyV1DeFi,
    IBittyV1BridgeAdapter,
    BridgeNotEnabled,
    InvalidBridgeProtocol,
    AssetNotBridgeable,
    BridgeAmountMismatch,
    BridgeToSelf
} from "../interfaces/IBittyV1DeFi.sol";
import {AddressZero, AmountIsZero, Deprecated} from "../interfaces/IBittyV1Vault.sol";
import {BittyStorage, DeFiStorage, TimelockedValue, VaultStorage} from "./BittyStorage.sol";
import {DeFiLogic} from "./DeFiLogic.sol";
import {MarketTradeLogic} from "./MarketTradeLogic.sol";
import {PaymentLogic} from "./PaymentLogic.sol";
import {WhitelistLogic} from "./WhitelistLogic.sol";
import {RiskLogic} from "./RiskLogic.sol";
import {TimelockLib} from "./TimelockLib.sol";
import {BITTY_GUARD, ASSET_BRIDGEABLE, PROTOCOL_BRIDGE} from "./Constants.sol";

/**
 * @title BridgeLogic
 * @notice The bridge function: its timelocked on-switch, the bridge to this vault's counterparts,
 *         the bridge to someone else's address, and the bridge to a whitelisted recipient on another
 *         chain. See {IBittyV1DeFi-bridge}, {IBittyV1DeFi-bridgeTo} and
 *         {IBittyV1DeFi-bridgeToWhitelistedRecipient}.
 * @dev Internal, so it compiles into the DeFi facet: the vault has no room for it, and a separate
 *      linked library would be one more address every deploy has to carry. Operates on the vault's
 *      {DeFiStorage} and {VaultStorage}, reached by delegatecall.
 *
 *      The switch is a {TimelockedValue} holding 1 for off, so a vault that never touched it reads as
 *      on without writing anything at activation, like market trading. It shares the timelock math
 *      the risk settings use: off applies at once, on waits out the risk timelock in force, and a lock
 *      drops a pending on ({LockLib-_engage}).
 */
library BridgeLogic {
    using SafeERC20 for IERC20;

    uint64 private constant OFF = 1;

    function setEnabled(bool enabled) internal {
        DeFiLogic._onlyInitialized();
        TimelockedValue storage tv = BittyStorage.defi().bridgeDisabled;
        uint64 timelock = RiskLogic.effectiveTimelock(BittyStorage.vault());
        bool loosen = enabled && TimelockLib.effective(tv) == OFF;
        TimelockLib.setCap(tv, enabled ? 0 : OFF, loosen, timelock);
        emit IBittyV1DeFi.BridgeEnabledSet(enabled, loosen ? tv.pendingAt : uint64(block.timestamp));
    }

    function settings() internal view returns (bool enabled, uint64 enableAt) {
        TimelockedValue storage tv = BittyStorage.defi().bridgeDisabled;
        enabled = TimelockLib.effective(tv) != OFF;
        if (!enabled && tv.pendingAt > block.timestamp) enableAt = tv.pendingAt;
    }

    /**
     * @dev What leaves is judged by the vault's own balance, not the adapter's word: exactly `amount`,
     *      no more and no less. For the native coin the vault unwraps its gas token and sends the
     *      value; anything the adapter sends back is wrapped again on arrival ({BittyV1Vault-receive}),
     *      so it shows up in the same balance and fails the check too.
     *
     *      What arrives on the other side the vault cannot see, so it takes the adapter's word, the
     *      amount the adapter has bound the bridge to pay out, in `asset`'s units. The difference,
     *      Bitty's fee and the bridge's cost, is charged to the daily loss allowance like a market
     *      trade's shortfall: a bridge moves money only between a vault and its counterparts, but
     *      each crossing costs something, and a leaked key bouncing the vault between chains would
     *      otherwise lose that cost without limit.
     */
    function bridge(address protocol, address asset, uint256 amount, uint256 fee, bytes calldata data) internal {
        VaultStorage storage v = BittyStorage.vault();
        address token = asset == address(0) ? v.gasWrapped : asset;
        MarketTradeInfo memory info = _info(protocol, token, amount);
        address clone = DeFiLogic._cloneProtocol(BittyStorage.defi(), protocol);
        uint256 before = IERC20(token).balanceOf(address(this));
        uint256 received;
        if (asset == address(0)) {
            WETH(payable(token)).withdraw(amount);
            received = IBittyV1BridgeAdapter(clone).bridge{value: amount}(address(0), amount, fee, data);
        } else {
            IERC20(token).forceApprove(clone, amount);
            received = IBittyV1BridgeAdapter(clone).bridge(token, amount, fee, data);
            _clearAllowance(token, clone);
        }
        if (IERC20(token).balanceOf(address(this)) + amount != before) revert BridgeAmountMismatch();
        MarketTradeLogic.chargeBridgeLoss(info, token, amount > received ? amount - received : 0);
        emit IBittyV1DeFi.Bridged(protocol, asset, amount, fee, received, data);
    }

    /**
     * @dev A bridge to someone else's address is a send that happens to cross chains: all of
     *      `amount` leaves the owner's hands, so all of it is metered against the send allowance,
     *      before anything moves, and nothing is charged to the loss allowance (the fee and the
     *      bridge's cost are part of what the allowance already counted). A stablecoin only, so
     *      the allowance can meter it without a price. The adapter pays `recipient` and nothing
     *      else; the exact-amount check is the same as {bridge}'s.
     */
    function bridgeTo(
        address protocol,
        address asset,
        uint256 amount,
        uint256 fee,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes calldata data
    ) internal {
        if (recipient == 0) revert AddressZero();
        if (recipient == bytes32(uint256(uint160(address(this))))) revert BridgeToSelf();
        address clone = _open(protocol, asset, amount);
        PaymentLogic.meterBridgeOut(asset, amount);
        uint256 received = _out(clone, asset, amount, fee, destinationChainId, recipient, data);
        emit IBittyV1DeFi.BridgedTo(protocol, asset, destinationChainId, recipient, amount, fee, received, data);
    }

    /**
     * @dev A payout to a whitelisted recipient that happens to cross chains: no amount limit and
     *      nothing metered, as for one here, once entry `id` is payable on `destinationChainId`
     *      (its own chain, or any EVM chain for an {ANY_EVM_CHAIN} entry). Allowed under either
     *      lock like such a payout, though only while the bridge function is on, which a lock
     *      cannot turn on. The entry fixes the address; the adapter is held to it, to the chain,
     *      and still to its route.
     */
    function bridgeToWhitelistedRecipient(
        address protocol,
        uint256 id,
        address asset,
        uint256 amount,
        uint256 fee,
        uint256 destinationChainId,
        bytes calldata data
    ) internal {
        bytes32 recipient = WhitelistLogic.payableRecipientOn(id, destinationChainId);
        address clone = _open(protocol, asset, amount);
        uint256 received = _out(clone, asset, amount, fee, destinationChainId, recipient, data);
        emit IBittyV1DeFi.WhitelistedRecipientBridged(
            id, protocol, asset, destinationChainId, recipient, amount, fee, received
        );
    }

    /**
     * @dev Hands `amount` of the ERC-20 `asset` to the adapter's clone for `recipient` on
     *      `destinationChainId`, and checks that exactly `amount` left.
     */
    function _out(
        address clone,
        address asset,
        uint256 amount,
        uint256 fee,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes calldata data
    ) private returns (uint256 received) {
        uint256 before = IERC20(asset).balanceOf(address(this));
        IERC20(asset).forceApprove(clone, amount);
        received = IBittyV1BridgeAdapter(clone).bridgeTo(asset, amount, fee, destinationChainId, recipient, data);
        _clearAllowance(asset, clone);
        if (IERC20(asset).balanceOf(address(this)) + amount != before) revert BridgeAmountMismatch();
    }

    /**
     * @dev The checks both bridges share: the vault is live, the amount is not zero, the bridge
     *      function is on, the protocol is a guard-registered bridge the vault may use, and the
     *      token is bridgeable. Returns the guard's record.
     */
    function _info(address protocol, address token, uint256 amount) private view returns (MarketTradeInfo memory info) {
        DeFiLogic._onlyInitialized();
        if (amount == 0) revert AmountIsZero();
        DeFiStorage storage $ = BittyStorage.defi();
        if (TimelockLib.effective($.bridgeDisabled) == OFF) revert BridgeNotEnabled();

        info = IBittyV1Guard(BITTY_GUARD).marketTradeInfo(protocol, token, token);
        if (info.protocolCategory != PROTOCOL_BRIDGE) revert InvalidBridgeProtocol();
        if (info.protocolDeprecated) revert Deprecated();
        if (BittyStorage.vault().ownAllowListActive && !$.protocols[protocol]) revert InvalidBridgeProtocol();
        if (info.buyCategory & ASSET_BRIDGEABLE == 0) revert AssetNotBridgeable();
    }

    /**
     * @dev {_info}'s checks, for an ERC-20 going to someone else's address, and the vault's clone
     *      of the adapter.
     */
    function _open(address protocol, address asset, uint256 amount) private returns (address) {
        _info(protocol, asset, amount);
        return DeFiLogic._cloneProtocol(BittyStorage.defi(), protocol);
    }

    function _clearAllowance(address token, address clone) private {
        if (IERC20(token).allowance(address(this), clone) != 0) IERC20(token).forceApprove(clone, 0);
    }
}
