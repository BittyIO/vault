// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1AccountBase} from "./BittyV1AccountBase.sol";
import {DeFiLogic} from "./logic/DeFiLogic.sol";
import {BittyStorage} from "./logic/BittyStorage.sol";
import {IBittyV1Guard, PROTOCOL_INTENT} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AutoYield} from "./interfaces/IBittyV1Vault.sol";
import {
    BITTY_GUARD,
    PERM_YIELD,
    PERM_SUPPLY,
    PERM_MARKET_TRADE,
    PERM_MARKET_MAKER,
    PERM_INTENT
} from "./logic/Constants.sol";
import {IBittyV1Guard as IGuard, PROTOCOL_STAKING} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1DeFi} from "./interfaces/IBittyV1DeFi.sol";

/**
 * @title BittyV1VaultDeFiFacet
 * @notice The DeFi surface, written once and delegatecalled by both the main vault and every sub vault.
 *         Authorisation is the inherited {onlyOwner}: since `owner()` lives at OZ's fixed ERC-7201 slot,
 *         `_msgSender() == owner()` resolves to the main owner inside the main vault and the sub owner
 *         inside a sub vault — the same code, correct authority in each host.
 * @dev Reached through each host's fallback, so it never holds its own state; every function operates on
 *      the host's co-located {DeFiStorage}. The allowlist *switch* is deliberately NOT here (that stays
 *      host-controlled — main owner / parent); only the list *content* is, since narrowing is pure
 *      self-restriction.
 */
contract BittyV1VaultDeFiFacet is BittyV1AccountBase {
    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;

    error NotAutoYieldTrigger();

    /**
     * @dev The OWNER may do everything here. A manager may do what it was GRANTED — see
     *      {PERMS_DEFAULT} for the bits and why market trade is not among the defaults.
     *
     *      The fallback is the owner check in both directions: a caller who is not a live manager,
     *      or is one without this capability, still passes if it is the owner. So these modifiers
     *      read as "the owner, or a manager trusted with this one thing", and no surface becomes
     *      unreachable to the person who owns the vault.
     */
    modifier onlyManagerWith(uint32 permission) {
        if (!DeFiLogic.assetManagerCan(_msgSender(), permission)) _checkOwner();
        _;
    }

    /**
     * @dev Unwinding is not a permission. Withdrawing a position, removing liquidity and claiming
     *      fees all move money back INTO the vault, so any live manager may do them however narrow
     *      its grant: a key allowed to put money to work has to be able to take it out again, and a
     *      key that can only bring money home cannot pay anyone with it.
     */
    modifier onlyUnwind() {
        if (!DeFiLogic.isActiveAssetManager(_msgSender())) _checkOwner();
        _;
    }

    /**
     * @dev Yielding and lending are one vault function and two capabilities, told apart by the
     *      adapter's own category on the guard: a manager appointed to run the savings position is
     *      not thereby appointed to lend on Aave. An adapter of any other category is refused by
     *      {DeFiLogic-deposit} itself, so the bit chosen for it here never decides anything.
     */
    function deposit(address protocol, address asset, uint256 amount) external {
        uint32 permission =
            IGuard(BITTY_GUARD).protocolCategory(protocol) == PROTOCOL_STAKING ? PERM_YIELD : PERM_SUPPLY;
        if (!DeFiLogic.assetManagerCan(_msgSender(), permission)) _checkOwner();
        DeFiLogic.deposit(protocol, asset, amount);
    }

    function withdraw(address protocol, address asset, uint256 amount) external onlyUnwind {
        DeFiLogic.withdraw(protocol, asset, amount, address(this));
    }

    function claimWithdrawals(address protocol, uint256[] memory ids) external onlyUnwind {
        DeFiLogic.claimWithdrawals(protocol, ids);
    }

    function claimWithdrawal(address protocol, uint256 id) external onlyUnwind {
        DeFiLogic.claimWithdrawalOne(protocol, id);
    }

    function getBalances(address[] calldata protocols, address[] calldata assets)
        external
        view
        returns (uint256[] memory)
    {
        return DeFiLogic.getBalances(protocols, assets);
    }

    function getPendingWithdrawalIds(address protocol) external view returns (uint256[] memory) {
        return DeFiLogic.getPendingWithdrawalIds(protocol);
    }

    function getClone(address protocol) external view returns (address) {
        return DeFiLogic.getClone(protocol);
    }

    function _onlyAutoYieldTrigger() private view {
        if (msg.sender == address(this)) return;
        address s = _msgSender();
        if (s == owner()) return;
        address trigger = DeFiLogic.autoYieldTrigger();
        if (trigger != address(0) && s == trigger) return;
        revert NotAutoYieldTrigger();
    }

    /**
     * @notice Appoint an asset manager, for the capabilities named in `permissions`.
     * @dev The owner's own description of the job: yield, lending, market trade, liquidity, intents
     *      — see {PERM_YIELD} and the note above it. The mask is always given; dropping a capability
     *      from a live grant takes effect at once, adding one waits out the change timelock, like
     *      every other widening in this vault.
     */
    function setAssetManager(address assetManager_, uint64 expiresAt, uint32 permissions) external onlyOwner {
        DeFiLogic.setAssetManager(assetManager_, expiresAt, permissions);
    }

    /**
     * @notice What the live asset manager may do, as a bit set; zero when there is none.
     */
    function assetManagerPermissions() external view returns (uint32) {
        return DeFiLogic.assetManagerPermissions();
    }

    function getAssetManagerSettings()
        external
        view
        returns (address manager, uint64 expiresAt, address pendingManager, uint64 pendingAt)
    {
        return DeFiLogic.getAssetManagerSettings();
    }

    function setAutoYieldTrigger(address trigger) external onlyOwner {
        DeFiLogic.setAutoYieldTrigger(trigger);
    }

    function autoYieldTrigger() external view returns (address) {
        return DeFiLogic.autoYieldTrigger();
    }

    function autoYield(address asset) external {
        _onlyAutoYieldTrigger();
        DeFiLogic.autoYieldOne(asset);
    }

    function autoYields(address[] calldata assets) external {
        _onlyAutoYieldTrigger();
        DeFiLogic.autoYield(assets);
    }

    function setAutoYielding(AutoYield calldata route) external onlyOwner {
        DeFiLogic.setAutoYieldingOne(route);
    }

    function setAutoYieldings(AutoYield[] calldata routes) external onlyOwner {
        DeFiLogic.setAutoYieldings(routes);
    }

    function getAutoYieldings(address[] calldata assets) external view returns (address[] memory) {
        return DeFiLogic.getAutoYieldings(assets);
    }

    function addLiquidity(
        address amm,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes memory data
    ) external onlyManagerWith(PERM_MARKET_MAKER) {
        DeFiLogic.addLiquidity(amm, token0, amount0, token1, amount1, data);
    }

    /**
     * @dev Market swaps are the OWNER's, not the asset manager's — the one trading surface the
     *      delegated key does not get.
     *
     *      A market order carries its own price: the caller chooses the route and the floor, and a
     *      floor of one wei turns a sale into a donation to whoever provides the liquidity on the
     *      way. {RouteGuard} now holds the route to the vault's allow list, which stops the value
     *      being handed to a token the manager minted, but it cannot say what the trade was WORTH —
     *      a single hop through a pool the manager is the only provider in is a route of perfectly
     *      allowed assets. Until the vault can price a trade, the only sound answer is that the key
     *      which is trusted to decide WHAT to trade is not trusted to decide AT WHAT PRICE.
     *
     *      So it is its own capability, and not one of the defaults: a manager reaches it only if
     *      the owner granted {PERM_MARKET_TRADE} by name, and adding that bit to a live grant waits
     *      out the change timelock like any other widening. The manager's ordinary surface is limit
     *      and TWAP orders, which are signed as intents — the order binds the receiver to this vault
     *      and a price, and solver competition fills it, so the manager picks the trade and the
     *      market sets the rate.
     */
    function marketSell(
        address amm,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmountMin,
        bytes memory path
    ) external onlyManagerWith(PERM_MARKET_TRADE) {
        DeFiLogic.marketSell(amm, sellToken, sellAmount, buyToken, buyAmountMin, path);
    }

    function marketBuy(
        address amm,
        address sellToken,
        uint256 sellAmountMax,
        address buyToken,
        uint256 buyAmount,
        bytes memory reversedPath
    ) external onlyManagerWith(PERM_MARKET_TRADE) {
        DeFiLogic.marketBuy(amm, sellToken, sellAmountMax, buyToken, buyAmount, reversedPath);
    }

    function removeLiquidity(address amm, bytes memory data) external onlyUnwind {
        DeFiLogic.removeLiquidity(amm, data);
    }

    function decreaseLiquidity(address amm, bytes memory data) external onlyUnwind {
        DeFiLogic.decreaseLiquidity(amm, data);
    }

    function claimAMMFees(address amm, bytes memory data) external onlyUnwind {
        DeFiLogic.claimAMMFees(amm, data);
    }

    function getLiquidities(address[] calldata amms, bytes[] calldata data) external view returns (uint256[] memory) {
        return DeFiLogic.getLiquidities(amms, data);
    }

    function approveIntentRelayer(address intent, address token) external onlyManagerWith(PERM_INTENT) {
        DeFiLogic.approveIntentRelayer(intent, token);
    }

    function cancelIntentOrders(address intent, bytes[] calldata uids) external onlyUnwind {
        DeFiLogic.cancelIntentOrders(intent, uids);
    }

    function cancelIntentOrder(address intent, bytes calldata uid) external onlyUnwind {
        DeFiLogic.cancelIntentOrderOne(intent, uid);
    }

    function updateProtocols(address[] calldata add, address[] calldata remove) external onlyOwner {
        DeFiLogic.updateProtocols(add, remove);
    }

    function upgradeProtocol(address protocol, address newImplementation) external onlyOwner {
        DeFiLogic.upgradeProtocol(protocol, newImplementation);
    }

    function updateAssets(address[] calldata add, address[] calldata remove) external onlyOwner {
        DeFiLogic.updateAssets(add, remove);
    }

    function isProtocolAllowed(address protocol) external view returns (bool) {
        return DeFiLogic.isProtocolAllowed(protocol);
    }

    function isAssetAllowed(address asset) external view returns (bool) {
        return DeFiLogic.assetAllowed(asset);
    }

    function allowlistEnabled() external view returns (bool) {
        return DeFiLogic.allowlistEnabled();
    }

    function guard() external pure returns (IBittyV1Guard) {
        return IBittyV1Guard(BITTY_GUARD);
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        bytes4 result = _validateThrough(IBittyV1Guard(BITTY_GUARD).getProtocols(), hash, signature);
        if (result == ERC1271_MAGIC_VALUE) return result;
        return _validateThrough(IBittyV1Guard(BITTY_GUARD).getDeprecatedProtocols(), hash, signature);
    }

    function _validateThrough(address[] memory protocols, bytes32 hash, bytes memory signature)
        private
        view
        returns (bytes4)
    {
        for (uint256 i; i < protocols.length; i++) {
            if (IBittyV1Guard(BITTY_GUARD).protocolCategory(protocols[i]) != PROTOCOL_INTENT) continue;
            address clone = DeFiLogic.getClone(protocols[i]);
            if (clone == address(0)) continue;
            try IBittyV1IntentProtocol(clone).isValidSignature(hash, signature) returns (bytes4 result) {
                if (result == ERC1271_MAGIC_VALUE) return result;
            } catch {}
        }
        return 0xffffffff;
    }

    /**
     * @dev The gate for limit and TWAP orders, which are signed OFF chain — so this view, not a
     *      modifier, is where a manager's intent capability is checked. See {PERM_INTENT} for why
     *      one bit covers both kinds.
     */
    function isOffchainOrderAuthorized(address signer, address sellToken, address buyToken, uint256 sellAmount)
        external
        view
        returns (bool)
    {
        if (signer != owner() && !DeFiLogic.assetManagerCan(signer, PERM_INTENT)) {
            return false;
        }
        if (!DeFiLogic.assetAllowed(buyToken)) return false;
        return IERC20(sellToken).balanceOf(address(this)) >= sellAmount;
    }

    function isOffchainCancellationAuthorized(address signer) external view returns (bool) {
        return signer == owner() || DeFiLogic.isActiveAssetManager(signer);
    }
}
