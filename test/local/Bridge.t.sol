// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN, ASSET_CRYPTO, ASSET_AMM_LIQUID} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {
    IBittyV1DeFi,
    BridgeNotEnabled,
    InvalidBridgeProtocol,
    AssetNotBridgeable,
    BridgeAmountMismatch,
    DailyLossAllowanceExceeded
} from "../../src/interfaces/IBittyV1DeFi.sol";
import {VaultLocked, Deprecated, AmountIsZero, PendingChanges} from "../../src/interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {
    BITTY_GUARD,
    LEGACY_RISK_TIMELOCK,
    ASSET_BRIDGEABLE,
    PROTOCOL_BRIDGE,
    PROTOCOL_MARKET_TRADE_ID
} from "./BridgeTestConstants.sol";

/**
 * @dev A bridge adapter that takes what it is handed and keeps it, standing in for a deposit into
 *      the bridge. `SHORT` makes it pull one unit less than asked, `RETURN` send half the native
 *      value straight back, so the vault's exact-amount check has something to catch. It reports
 *      `amount - fee` less `costBps` of the deposit as what arrives, like a real adapter's quote.
 */
contract MockBridge {
    uint8 public constant HONEST = 0;
    uint8 public constant SHORT = 1;
    uint8 public constant RETURN = 2;

    uint8 public immutable mode;
    uint256 public immutable costBps;

    event Got(address token, uint256 amount, uint256 fee, uint256 value, bytes data);

    constructor(uint8 mode_, uint256 costBps_) {
        mode = mode_;
        costBps = costBps_;
    }

    function initialize(address) external {}

    function protocolLineage() external pure returns (bytes32) {
        return keccak256("bitty.mock.bridge");
    }

    function protocolVersion() external pure returns (uint256) {
        return 1_000_000;
    }

    function bridge(address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        payable
        returns (uint256 received)
    {
        if (token != address(0)) {
            IERC20(token).transferFrom(msg.sender, address(this), mode == SHORT ? amount - 1 : amount);
        } else if (mode == RETURN) {
            (bool ok,) = msg.sender.call{value: msg.value / 2}("");
            require(ok);
        }
        emit Got(token, amount, fee, msg.value, data);
        received = (amount - fee) * (10_000 - costBps) / 10_000;
    }

    receive() external payable {}
}

/**
 * The bridge: owner only, off until turned on (which waits out the risk timelock), never under a
 * lock, and exactly the stated amount leaves the vault. No amount limit: the destination is the
 * owner's own vault on another chain.
 */
contract BridgeFeed {
    int256 public answer;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function set(int256 answer_) external {
        answer = answer_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

contract BridgeTest is Test {
    event Got(address token, uint256 amount, uint256 fee, uint256 value, bytes data);

    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 dai;
    WETH weth;
    MockBridge across;

    address owner = makeAddr("owner");
    bytes constant DATA = abi.encode(bytes32(uint256(1)));

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        weth = new WETH();
        BittyV1Vault impl = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, address(weth), false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        across = new MockBridge(0, 0);

        guard.setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID | ASSET_BRIDGEABLE);
        guard.setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID); // not bridgeable
        guard.setAsset(address(weth), ASSET_CRYPTO | ASSET_AMM_LIQUID | ASSET_BRIDGEABLE);
        guard.setProtocol(address(across), PROTOCOL_BRIDGE);
        BridgeFeed ethUsd = new BridgeFeed();
        ethUsd.set(3_000e8);
        guard.setPriceFeed(address(weth), address(ethUsd), 1 hours, address(0));

        usdc.mint(address(vault), 1_000_000e6);
        dai.mint(address(vault), 1_000e18);
        vm.deal(address(this), 10 ether);
        weth.deposit{value: 10 ether}();
        weth.transfer(address(vault), 10 ether);
    }

    function _b() internal view returns (IBittyV1DeFi) {
        return IBittyV1DeFi(address(vault));
    }

    function _enable() internal {
        vm.prank(owner);
        _b().setBridgeEnabled(true);
        vm.warp(block.timestamp + LEGACY_RISK_TIMELOCK);
    }

    function _disable() internal {
        vm.prank(owner);
        _b().setBridgeEnabled(false);
    }

    /// The owner sets a day's timelock, so turning the bridge on has something to wait out.
    function _aDayTimelock() internal {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(1 days, type(uint256).max, type(uint256).max));
    }

    function _bridge(address protocol, address asset, uint256 amount, uint256 fee) internal {
        vm.prank(owner);
        _b().bridge(protocol, asset, amount, fee, DATA);
    }

    function _clone(address protocol) internal view returns (address) {
        return BittyV1VaultDeFiFacet(payable(address(vault))).getClone(protocol);
    }

    // ── the on-switch ───────────────────────────────────────────────────────────────────────────

    function test_onByDefault() public {
        (bool enabled, uint64 enableAt) = _b().bridgeSettings();
        assertTrue(enabled);
        assertEq(enableAt, 0);
        assertEq(vault.pendingChanges().bridgeEnableAt, 0);
        _bridge(address(across), address(usdc), 1_000e6, 0);
    }

    function test_turningOnWhenAlreadyOnChangesNothing() public {
        vm.expectEmit(address(vault));
        emit IBittyV1DeFi.BridgeEnabledSet(true, uint64(block.timestamp));
        vm.prank(owner);
        _b().setBridgeEnabled(true);
        (bool enabled, uint64 enableAt) = _b().bridgeSettings();
        assertTrue(enabled);
        assertEq(enableAt, 0);
        assertEq(vault.pendingChanges().bridgeEnableAt, 0);
    }

    function test_turningOnWaitsOutTheTimelock() public {
        _aDayTimelock();
        _disable();
        vm.expectEmit(address(vault));
        emit IBittyV1DeFi.BridgeEnabledSet(true, uint64(block.timestamp + LEGACY_RISK_TIMELOCK));
        vm.prank(owner);
        _b().setBridgeEnabled(true);

        (bool enabled, uint64 enableAt) = _b().bridgeSettings();
        assertFalse(enabled);
        assertEq(enableAt, block.timestamp + LEGACY_RISK_TIMELOCK);

        vm.warp(block.timestamp + LEGACY_RISK_TIMELOCK - 1);
        vm.expectRevert(BridgeNotEnabled.selector);
        _bridge(address(across), address(usdc), 1_000e6, 0);

        vm.warp(block.timestamp + 1);
        (enabled, enableAt) = _b().bridgeSettings();
        assertTrue(enabled);
        assertEq(enableAt, 0);
        _bridge(address(across), address(usdc), 1_000e6, 0);
    }

    function test_turningOffIsImmediate() public {
        _enable();
        vm.prank(owner);
        _b().setBridgeEnabled(false);
        (bool enabled,) = _b().bridgeSettings();
        assertFalse(enabled);
        vm.expectRevert(BridgeNotEnabled.selector);
        _bridge(address(across), address(usdc), 1_000e6, 0);
    }

    function test_turningOffCancelsAPendingOn() public {
        _disable();
        vm.prank(owner);
        _b().setBridgeEnabled(true);
        vm.prank(owner);
        _b().setBridgeEnabled(false);
        vm.warp(block.timestamp + LEGACY_RISK_TIMELOCK);
        (bool enabled, uint64 enableAt) = _b().bridgeSettings();
        assertFalse(enabled);
        assertEq(enableAt, 0);
    }

    function test_pendingTurnOnIsInPendingChanges() public {
        _aDayTimelock();
        assertEq(vault.pendingChanges().bridgeEnableAt, 0);
        _disable();
        assertEq(vault.pendingChanges().bridgeEnableAt, 0);

        vm.prank(owner);
        _b().setBridgeEnabled(true);
        uint64 at = uint64(block.timestamp + LEGACY_RISK_TIMELOCK);
        assertEq(vault.pendingChanges().bridgeEnableAt, at);

        // Once it lands it is no longer pending.
        vm.warp(at);
        assertEq(vault.pendingChanges().bridgeEnableAt, 0);

        // Turning off never waits, so it never shows up as pending.
        vm.prank(owner);
        _b().setBridgeEnabled(false);
        assertEq(vault.pendingChanges().bridgeEnableAt, 0);

        // A turn-on dropped by turning off again, or by a lock, leaves the list.
        vm.prank(owner);
        _b().setBridgeEnabled(true);
        vm.prank(owner);
        _b().setBridgeEnabled(false);
        assertEq(vault.pendingChanges().bridgeEnableAt, 0);

        vm.prank(owner);
        _b().setBridgeEnabled(true);
        vm.prank(owner);
        vault.emergencyLock();
        PendingChanges memory p = vault.pendingChanges();
        assertEq(p.bridgeEnableAt, 0);
        assertEq(p.lockLevel, 1);
    }

    function test_onlyOwnerSwitches() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        _b().setBridgeEnabled(true);
    }

    // ── locks ───────────────────────────────────────────────────────────────────────────────────

    function test_lockDropsAPendingOn() public {
        _aDayTimelock();
        _disable();
        vm.prank(owner);
        _b().setBridgeEnabled(true);
        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vault.unlock();
        vm.warp(block.timestamp + LEGACY_RISK_TIMELOCK);
        (bool enabled,) = _b().bridgeSettings();
        assertFalse(enabled);
    }

    function test_lockKeepsAnOnThatAlreadyLanded() public {
        _enable();
        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vault.unlock();
        (bool enabled,) = _b().bridgeSettings();
        assertTrue(enabled);
    }

    function test_noBridgeUnderALock() public {
        _enable();
        vm.prank(owner);
        vault.emergencyLock();
        vm.expectRevert(VaultLocked.selector);
        _bridge(address(across), address(usdc), 1_000e6, 0);
    }

    function test_underALockOnIsRefusedButOffIsNot() public {
        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        _b().setBridgeEnabled(true);
        vm.prank(owner);
        _b().setBridgeEnabled(false);
    }

    // ── the bridge ──────────────────────────────────────────────────────────────────────────────

    function test_erc20_exactAmountToTheClone() public {
        _enable();
        uint256 before = usdc.balanceOf(address(vault));
        vm.expectEmit(address(vault));
        emit IBittyV1DeFi.Bridged(address(across), address(usdc), 1_000e6, 2e6, 998e6, DATA);
        _bridge(address(across), address(usdc), 1_000e6, 2e6);

        address clone = _clone(address(across));
        assertEq(before - usdc.balanceOf(address(vault)), 1_000e6);
        assertEq(usdc.balanceOf(clone), 1_000e6);
        assertEq(usdc.allowance(address(vault), clone), 0);
    }

    /**
     * No amount limit: a new vault starts with regular sends OFF, and the bridge still moves
     * everything, since it goes to the owner's own vault.
     */
    function test_noAmountLimit() public {
        _enable();
        _bridge(address(across), address(usdc), 1_000_000e6, 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_native_unwrapsAndSendsValue() public {
        _enable();
        address clone = _clone(address(across)); // not yet created
        assertEq(clone, address(0));
        _bridge(address(across), address(0), 1 ether, 0.002 ether);
        clone = _clone(address(across));
        assertEq(weth.balanceOf(address(vault)), 9 ether);
        assertEq(clone.balance, 1 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_adapterTakingLessIsRefused() public {
        MockBridge short = new MockBridge(1, 0);
        guard.setProtocol(address(short), PROTOCOL_BRIDGE);
        _enable();
        vm.expectRevert(BridgeAmountMismatch.selector);
        _bridge(address(short), address(usdc), 1_000e6, 0);
    }

    function test_adapterSendingNativeBackIsRefused() public {
        MockBridge back = new MockBridge(2, 0);
        guard.setProtocol(address(back), PROTOCOL_BRIDGE);
        _enable();
        vm.expectRevert(BridgeAmountMismatch.selector);
        _bridge(address(back), address(0), 1 ether, 0);
    }

    function test_onlyOwnerBridges() public {
        _enable();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        _b().bridge(address(across), address(usdc), 1_000e6, 0, DATA);
    }

    function test_protocolMustBeABridge() public {
        MockBridge market = new MockBridge(0, 0);
        guard.setProtocol(address(market), PROTOCOL_MARKET_TRADE_ID);
        _enable();
        vm.expectRevert(InvalidBridgeProtocol.selector);
        _bridge(address(market), address(usdc), 1_000e6, 0);

        vm.expectRevert(InvalidBridgeProtocol.selector);
        _bridge(makeAddr("unregistered"), address(usdc), 1_000e6, 0);
    }

    function test_deprecatedBridgeRefused() public {
        guard.setDeprecated(address(across), true);
        _enable();
        vm.expectRevert(Deprecated.selector);
        _bridge(address(across), address(usdc), 1_000e6, 0);
    }

    function test_assetMustBeBridgeable() public {
        _enable();
        vm.expectRevert(AssetNotBridgeable.selector);
        _bridge(address(across), address(dai), 1e18, 0);

        guard.setAsset(address(weth), ASSET_CRYPTO | ASSET_AMM_LIQUID);
        vm.expectRevert(AssetNotBridgeable.selector);
        _bridge(address(across), address(0), 1 ether, 0);
    }

    function test_ownAllowListMustNameTheBridge() public {
        _enable();
        vm.prank(owner);
        BittyV1VaultDeFiFacet(payable(address(vault))).useBittyAllowList(false);
        vm.expectRevert(InvalidBridgeProtocol.selector);
        _bridge(address(across), address(usdc), 1_000e6, 0);
    }

    function test_zeroAmountRefused() public {
        _enable();
        vm.expectRevert(AmountIsZero.selector);
        _bridge(address(across), address(usdc), 0, 0);
    }

    // ── the daily loss allowance ────────────────────────────────────────────────────────────────

    function _setDailyLoss(uint256 usd) internal {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(type(uint256).max, type(uint256).max, usd));
    }

    /// A new vault may lose 1,000 USD a day; the fee and the bridge's cost both count.
    function test_lossIsChargedToTheDailyAllowance() public {
        MockBridge costly = new MockBridge(0, 100); // the bridge keeps 1%
        guard.setProtocol(address(costly), PROTOCOL_BRIDGE);
        _enable();
        _bridge(address(costly), address(usdc), 50_000e6, 0); // loses 500
        _bridge(address(costly), address(usdc), 40_000e6, 80e6); // 80 fee + 399.2 cost = 479.2, 979.2 in all
        vm.expectRevert(DailyLossAllowanceExceeded.selector);
        _bridge(address(costly), address(usdc), 10_000e6, 0); // 100 more is over
    }

    /// A leaked key bouncing the vault between chains loses at most the allowance a day.
    function test_theAllowanceResetsAfterADay() public {
        MockBridge costly = new MockBridge(0, 100);
        guard.setProtocol(address(costly), PROTOCOL_BRIDGE);
        _enable();
        _bridge(address(costly), address(usdc), 100_000e6, 0); // loses exactly 1,000
        vm.expectRevert(DailyLossAllowanceExceeded.selector);
        _bridge(address(costly), address(usdc), 1_000e6, 0);
        vm.warp(block.timestamp + 1 days);
        _bridge(address(costly), address(usdc), 1_000e6, 0);
    }

    function test_lossOnTheNativeCoinIsPricedAtOracle() public {
        _enable();
        _setDailyLoss(5);
        // 0.002 ETH fee at 3,000 USD is 6 USD, over a 5 USD allowance.
        vm.expectRevert(DailyLossAllowanceExceeded.selector);
        _bridge(address(across), address(0), 1 ether, 0.002 ether);
        _bridge(address(across), address(0), 1 ether, 0.001 ether); // 3 USD
    }

    /// At 0 the allowance turns off every bridge that loses anything, as it does market trading.
    function test_zeroAllowanceRefusesALossyBridge() public {
        _enable();
        _setDailyLoss(0);
        vm.expectRevert(DailyLossAllowanceExceeded.selector);
        _bridge(address(across), address(usdc), 1_000e6, 1e6);
        _bridge(address(across), address(usdc), 1_000e6, 0); // loses nothing
    }
}
