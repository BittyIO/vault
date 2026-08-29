// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {MockAMMProtocol} from "../helpers/MockAMMProtocol.sol";
import {MockIntentProtocol} from "../helpers/MockIntentProtocol.sol";
import {MockSettlement} from "../helpers/MockSettlement.sol";
import {AMM_ID, INTENT_ID, LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {AutoYield} from "../../src/interfaces/IBittyV1Vault.sol";
import {AddressZero, ArrayLengthMismatch, Deprecated, NotRegistered} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    InvalidAMMProtocol,
    InvalidIntentProtocol,
    InvalidDepositableProtocol,
    disableTradeUntilTimestampTooLong
} from "../../src/interfaces/IBittyV1DeFi.sol";
import {BITTY_GUARD, STABLE_COIN_CATEGORY} from "../../src/logic/Constants.sol";

interface IFacet {
    function deposit(address protocol, address asset, uint256 amount) external;
    function updateAssets(address[] calldata add, address[] calldata remove) external;
    function updateProtocols(address[] calldata add, address[] calldata remove) external;
    function isAssetAllowed(address asset) external view returns (bool);
    function isProtocolAllowed(address protocol) external view returns (bool);
    function allowlistEnabled() external view returns (bool);
    function enableAllowlist() external;
    function setAutoYielding(AutoYield calldata route) external;
    function setAutoYieldings(AutoYield[] calldata routes) external;
    function getAutoYieldings(address[] calldata assets) external view returns (address[] memory);
    function autoYield(address asset) external;
    function autoYields(address[] calldata assets) external;
    function getClone(address protocol) external view returns (address);
    function addLiquidity(address amm, address t0, uint256 a0, address t1, uint256 a1, bytes memory data) external;
    function removeLiquidity(address amm, bytes memory data) external;
    function decreaseLiquidity(address amm, bytes memory data) external;
    function claimAMMFees(address amm, bytes memory data) external;
    function getLiquidities(address[] calldata amms, bytes[] calldata data) external view returns (uint256[] memory);
    function approveIntentRelayer(address intent, address token) external;
    function cancelIntentOrder(address intent, bytes calldata uid) external;
    function disableTradeUntilTimestamp(uint256 ts) external;
    function setAutoYieldTrigger(address trigger) external;
    function autoYieldTrigger() external view returns (address);
    function cancelIntentOrders(address intent, bytes[] calldata uids) external;
    function guard() external view returns (address);
}

/// A position NFT that records whether the vault ever granted blanket approval.
contract PositionNFT {
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

/// An AMM whose clone reports a position NFT, so the liquidity path has an NFT to approve.
contract NFTAwareAMM is MockAMMProtocol {
    address internal immutable _nft;

    constructor(address nft) {
        _nft = nft;
    }

    function positionAssetManager() external view returns (address) {
        return _nft;
    }
}

/// Reports a position NFT the vault cannot probe — the staticcall answers nothing usable.
contract SilentNFTAMM is MockAMMProtocol {
    address internal immutable _nft;

    constructor(address nft) {
        _nft = nft;
    }

    function positionAssetManager() external view returns (address) {
        return _nft;
    }
}

/**
 * The guardrails around the DeFi surface: deprecation, the local allowlist's two-way switch, and the
 * argument handling on auto-yield and AMM calls.
 *
 * Deprecation is the guard's one-way exit — a protocol the vault may still WITHDRAW from but must not
 * put new money into. The allowlist is the owner's own narrowing, and it tightens instantly but loosens
 * on a timelock, so a stolen key cannot widen the vault's reach in one transaction.
 */
contract DeFiGuardrailsTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 dai;
    MockLendingProtocol proto;
    MockAMMProtocol amm;
    MockIntentProtocol intent;
    MockSettlement settlement;

    address owner = makeAddr("owner");
    address weth = makeAddr("weth");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        proto = new MockLendingProtocol();
        amm = new MockAMMProtocol();
        settlement = new MockSettlement();
        intent = new MockIntentProtocol();
        intent.setEndpoints(address(settlement), address(settlement));

        guard.setAsset(address(usdc), STABLE_COIN_CATEGORY);
        guard.setAsset(address(dai), STABLE_COIN_CATEGORY);
        guard.setProtocol(address(proto), LENDING_ID);
        guard.setProtocol(address(amm), AMM_ID);
        guard.setProtocol(address(intent), INTENT_ID);

        usdc.mint(address(vault), 1_000e6);
        dai.mint(address(vault), 1_000e18);
    }

    function _f() internal view returns (IFacet) {
        return IFacet(address(vault));
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    // ── deprecation ───────────────────────────────────────────────────────────

    function test_aDeprecatedProtocolTakesNoNewDeposits() public {
        guard.setDeprecated(address(proto), true);
        vm.prank(owner);
        vm.expectRevert(InvalidDepositableProtocol.selector);
        _f().deposit(address(proto), address(usdc), 10e6);
    }

    function test_moneyAlreadyInADeprecatedProtocolStillComesOut() public {
        vm.prank(owner);
        _f().deposit(address(proto), address(usdc), 100e6);
        guard.setDeprecated(address(proto), true);

        vm.prank(owner);
        BittyV1Vault(payable(address(vault)));
        (bool ok,) = address(vault)
            .call(abi.encodeWithSignature("withdraw(address,address,uint256)", address(proto), address(usdc), 100e6));
        assertTrue(ok, "deprecation is an exit, not a trap");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "everything came back");
    }

    function test_aDeprecatedAmmRefusesNewLiquidity() public {
        guard.setDeprecated(address(amm), true);
        vm.prank(owner);
        vm.expectRevert(Deprecated.selector);
        _f().addLiquidity(address(amm), address(usdc), 1e6, address(dai), 1e18, "");
    }

    function test_aDeprecatedIntentProtocolSignsNothingNew() public {
        guard.setDeprecated(address(intent), true);
        vm.prank(owner);
        vm.expectRevert(Deprecated.selector);
        _f().approveIntentRelayer(address(intent), address(usdc));
    }

    // ── the local allowlist ───────────────────────────────────────────────────

    function test_theAllowlistTightensImmediately() public {
        vm.startPrank(owner);
        _f().enableAllowlist();
        assertTrue(_f().allowlistEnabled(), "on the moment it is asked for");
        assertFalse(_f().isAssetAllowed(address(usdc)), "and nothing is named yet");
        vm.stopPrank();
    }

    function test_underTheAllowlistOnlyNamedThingsAreReachable() public {
        vm.startPrank(owner);
        _f().enableAllowlist();
        _f().updateAssets(_one(address(usdc)), _none());
        _f().updateProtocols(_one(address(proto)), _none());
        vm.stopPrank();

        assertTrue(_f().isAssetAllowed(address(usdc)), "named");
        assertFalse(_f().isAssetAllowed(address(dai)), "not named");
        assertTrue(_f().isProtocolAllowed(address(proto)), "named");
        assertFalse(_f().isProtocolAllowed(address(amm)), "not named");
    }

    function test_theAllowlistCannotNameSomethingTheGuardRejects() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);
        vm.startPrank(owner);
        _f().enableAllowlist();
        vm.expectRevert(NotRegistered.selector);
        _f().updateAssets(_one(address(rnd)), _none());
        vm.stopPrank();
    }

    function test_theAllowlistCannotNameAProtocolTheGuardRejects() public {
        vm.startPrank(owner);
        _f().enableAllowlist();
        vm.expectRevert(NotRegistered.selector);
        _f().updateProtocols(_one(makeAddr("nowhere")), _none());
        vm.stopPrank();
    }

    function test_removingAnAssetFromTheAllowlistClosesIt() public {
        vm.startPrank(owner);
        _f().enableAllowlist();
        _f().updateAssets(_one(address(usdc)), _none());
        _f().updateAssets(_none(), _one(address(usdc)));
        vm.stopPrank();
        assertFalse(_f().isAssetAllowed(address(usdc)), "no longer named");
    }

    function test_removingAProtocolFromTheAllowlistClosesIt() public {
        vm.startPrank(owner);
        _f().enableAllowlist();
        _f().updateProtocols(_one(address(proto)), _none());
        _f().updateProtocols(_none(), _one(address(proto)));
        vm.stopPrank();
        assertFalse(_f().isProtocolAllowed(address(proto)), "no longer named");
    }

    function test_anUnnamedAssetCannotBeUsedForLiquidityWhileTheAllowlistIsOn() public {
        vm.startPrank(owner);
        _f().enableAllowlist();
        _f().updateProtocols(_one(address(amm)), _none());
        _f().updateAssets(_one(address(usdc)), _none());

        vm.expectRevert(NotRegistered.selector);
        _f().addLiquidity(address(amm), address(usdc), 1e6, address(dai), 1e18, "");
        vm.stopPrank();
    }

    function test_disablingTheAllowlistWaitsOutTheTimelockThenLapses() public {
        vm.startPrank(owner);
        vault.updatePaymentRisk(
            IBittyV1Owner.PaymentRisk({
                maxSendValue: UNCHANGED,
                maxSendInterval: UNCHANGED,
                newPaymentProtection: UNCHANGED,
                changeTimelock: 2 days
            })
        );
        _f().enableAllowlist();
        vault.disableAllowlist();
        assertTrue(_f().allowlistEnabled(), "still on while the timelock runs");
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        assertFalse(_f().allowlistEnabled(), "and off once it matures");
    }

    /// The matured pending-disable is settled lazily, on the first call that actually reads it.
    function test_theLapsedAllowlistIsSettledOnTheNextWrite() public {
        vm.startPrank(owner);
        vault.updatePaymentRisk(
            IBittyV1Owner.PaymentRisk({
                maxSendValue: UNCHANGED,
                maxSendInterval: UNCHANGED,
                newPaymentProtection: UNCHANGED,
                changeTimelock: 2 days
            })
        );
        _f().enableAllowlist();
        vault.disableAllowlist();
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        _f().deposit(address(proto), address(usdc), 10e6);
        assertFalse(_f().allowlistEnabled(), "the deposit went through and cleared the flag");
    }

    function test_disablingAnAllowlistThatIsAlreadyOffIsANoOp() public {
        vm.prank(owner);
        vault.disableAllowlist();
        assertFalse(_f().allowlistEnabled());
    }

    function test_reEnablingClearsAPendingDisable() public {
        vm.startPrank(owner);
        vault.updatePaymentRisk(
            IBittyV1Owner.PaymentRisk({
                maxSendValue: UNCHANGED,
                maxSendInterval: UNCHANGED,
                newPaymentProtection: UNCHANGED,
                changeTimelock: 2 days
            })
        );
        _f().enableAllowlist();
        vault.disableAllowlist();
        _f().enableAllowlist();
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        assertTrue(_f().allowlistEnabled(), "the scheduled loosening was cancelled");
    }

    // ── auto-yield routes ─────────────────────────────────────────────────────

    function test_aRouteCannotBeSetForTheZeroAsset() public {
        vm.prank(owner);
        vm.expectRevert(AddressZero.selector);
        _f().setAutoYielding(AutoYield({asset: address(0), protocol: address(proto)}));
    }

    function test_aRouteToTheZeroProtocolClearsIt() public {
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        assertEq(_f().getAutoYieldings(_one(address(usdc)))[0], address(proto), "set");

        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(0)}));
        assertEq(_f().getAutoYieldings(_one(address(usdc)))[0], address(0), "cleared");
        vm.stopPrank();
    }

    function test_aRouteToAProtocolTheGuardRejectsIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(InvalidDepositableProtocol.selector);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: makeAddr("nowhere")}));
    }

    function test_severalRoutesAreSetInOneCall() public {
        AutoYield[] memory routes = new AutoYield[](2);
        routes[0] = AutoYield({asset: address(usdc), protocol: address(proto)});
        routes[1] = AutoYield({asset: address(dai), protocol: address(proto)});
        vm.prank(owner);
        _f().setAutoYieldings(routes);

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        address[] memory got = _f().getAutoYieldings(assets);
        assertEq(got[0], address(proto));
        assertEq(got[1], address(proto));
    }

    function test_autoYieldingAnAssetWithNoRouteDoesNothing() public {
        vm.prank(owner);
        _f().autoYield(address(usdc));
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "untouched");
    }

    function test_autoYieldingAnEmptyBalanceDoesNothing() public {
        MockERC20 empty = new MockERC20("Empty", "EMP", 18);
        guard.setAsset(address(empty), STABLE_COIN_CATEGORY);
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(empty), protocol: address(proto)}));
        _f().autoYield(address(empty));
        vm.stopPrank();
        assertEq(_f().getClone(address(proto)), address(0), "nothing to deploy, so nothing was cloned");
    }

    function test_severalAssetsAreSweptInOneCall() public {
        AutoYield[] memory routes = new AutoYield[](2);
        routes[0] = AutoYield({asset: address(usdc), protocol: address(proto)});
        routes[1] = AutoYield({asset: address(dai), protocol: address(proto)});
        vm.prank(owner);
        _f().setAutoYieldings(routes);

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(dai);
        vm.prank(owner);
        _f().autoYields(assets);

        address clone = _f().getClone(address(proto));
        assertEq(usdc.balanceOf(clone), 1_000e6, "usdc deployed");
        assertEq(dai.balanceOf(clone), 1_000e18, "dai deployed");
    }

    // ── AMM argument handling ─────────────────────────────────────────────────

    function test_ammCallsOnANeverUsedProtocolAreRefused() public {
        vm.startPrank(owner);
        vm.expectRevert(InvalidAMMProtocol.selector);
        _f().removeLiquidity(address(amm), "");

        vm.expectRevert(InvalidAMMProtocol.selector);
        _f().decreaseLiquidity(address(amm), "");

        vm.expectRevert(InvalidAMMProtocol.selector);
        _f().claimAMMFees(address(amm), "");
        vm.stopPrank();
    }

    function test_aNonAmmProtocolCannotProvideLiquidity() public {
        vm.prank(owner);
        vm.expectRevert(InvalidAMMProtocol.selector);
        _f().addLiquidity(address(proto), address(usdc), 1e6, address(dai), 1e18, "");
    }

    function test_readingLiquiditiesWithRaggedArraysIsRefused() public {
        address[] memory amms = new address[](2);
        amms[0] = address(amm);
        amms[1] = address(amm);
        vm.expectRevert(ArrayLengthMismatch.selector);
        _f().getLiquidities(amms, new bytes[](1));
    }

    function test_aNonIntentProtocolCannotBeAskedToCancel() public {
        vm.prank(owner);
        vm.expectRevert(InvalidIntentProtocol.selector);
        _f().cancelIntentOrder(address(proto), hex"00");
    }

    // ── trade disable ─────────────────────────────────────────────────────────

    function test_disablingTradingUntilZeroIsANoOp() public {
        vm.prank(owner);
        _f().disableTradeUntilTimestamp(0);
    }

    function test_tradingCannotBeDisabledBeyondTheMaximumHorizon() public {
        vm.prank(owner);
        vm.expectRevert(disableTradeUntilTimestampTooLong.selector);
        _f().disableTradeUntilTimestamp(block.timestamp + 3650 days);
    }

    // ── the view helpers answer for things the guard never registered ─────────

    function test_anUnregisteredAssetIsNeverAllowed() public {
        assertFalse(_f().isAssetAllowed(makeAddr("nothing")), "the guard does not know it");
    }

    function test_anUnregisteredProtocolIsNeverAllowed() public {
        assertFalse(_f().isProtocolAllowed(makeAddr("nothing")), "the guard does not know it");
    }

    function test_aNonStablecoinIsNotSpendableUnderACap() public {
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        guard.setAsset(address(wbtc), 2);
        assertFalse(vault.isStableCoinAllowed(address(wbtc)), "registered, but the wrong category");
    }

    function test_anUnregisteredAssetIsNotASpendableStablecoin() public {
        assertFalse(vault.isStableCoinAllowed(makeAddr("nothing")), "not registered at all");
    }

    function test_aRegisteredStablecoinIsSpendable() public view {
        assertTrue(vault.isStableCoinAllowed(address(usdc)));
    }

    // ── position-NFT approval on the liquidity path ───────────────────────────

    function test_theCloneIsGrantedTheNftItNeedsToManagePositions() public {
        PositionNFT nft = new PositionNFT();
        NFTAwareAMM nftAmm = new NFTAwareAMM(address(nft));
        guard.setProtocol(address(nftAmm), AMM_ID);

        vm.prank(owner);
        _f().addLiquidity(address(nftAmm), address(usdc), 1e6, address(dai), 1e18, "");

        address clone = _f().getClone(address(nftAmm));
        assertTrue(nft.isApprovedForAll(address(vault), clone), "the clone can move the position NFT");
    }

    function test_theApprovalIsNotGrantedTwice() public {
        PositionNFT nft = new PositionNFT();
        NFTAwareAMM nftAmm = new NFTAwareAMM(address(nft));
        guard.setProtocol(address(nftAmm), AMM_ID);

        vm.startPrank(owner);
        _f().addLiquidity(address(nftAmm), address(usdc), 1e6, address(dai), 1e18, "");
        _f().removeLiquidity(address(nftAmm), "");
        vm.stopPrank();

        address clone = _f().getClone(address(nftAmm));
        assertTrue(nft.isApprovedForAll(address(vault), clone), "still approved, and not re-granted");
    }

    /// A "position NFT" that is not a contract cannot be probed; the vault skips it rather than reverting.
    function test_anUnprobeableNftIsSkippedNotFatal() public {
        SilentNFTAMM oddAmm = new SilentNFTAMM(makeAddr("notAContract"));
        guard.setProtocol(address(oddAmm), AMM_ID);

        vm.prank(owner);
        _f().addLiquidity(address(oddAmm), address(usdc), 1e6, address(dai), 1e18, "");
        assertTrue(_f().getClone(address(oddAmm)) != address(0), "liquidity still went in");
    }

    // ── the delegated auto-yield trigger ──────────────────────────────────────

    function test_thereIsNoDelegatedTriggerByDefault() public view {
        assertEq(_f().autoYieldTrigger(), address(0), "only the owner, until one is named");
    }

    function test_aStrangerCannotTriggerASweep() public {
        vm.prank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BittyV1VaultDeFiFacet.NotAutoYieldTrigger.selector);
        _f().autoYield(address(usdc));
    }

    function test_theNamedTriggerMaySweepButNothingElse() public {
        address keeper = makeAddr("keeper");
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        _f().setAutoYieldTrigger(keeper);
        vm.stopPrank();

        vm.prank(keeper);
        _f().autoYield(address(usdc));
        assertEq(usdc.balanceOf(_f().getClone(address(proto))), 1_000e6, "the keeper swept it");

        vm.prank(keeper);
        vm.expectRevert();
        _f().setAutoYielding(AutoYield({asset: address(dai), protocol: address(proto)}));
    }

    function test_theTriggerCanBeRotatedAndRevoked() public {
        address oldKeeper = makeAddr("oldKeeper");
        address newKeeper = makeAddr("newKeeper");
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        _f().setAutoYieldTrigger(oldKeeper);
        _f().setAutoYieldTrigger(newKeeper);
        vm.stopPrank();

        vm.prank(oldKeeper);
        vm.expectRevert(BittyV1VaultDeFiFacet.NotAutoYieldTrigger.selector);
        _f().autoYield(address(usdc));

        vm.prank(owner);
        _f().setAutoYieldTrigger(address(0));
        vm.prank(newKeeper);
        vm.expectRevert(BittyV1VaultDeFiFacet.NotAutoYieldTrigger.selector);
        _f().autoYield(address(usdc));
    }

    function test_onlyTheOwnerNamesTheTrigger() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        _f().setAutoYieldTrigger(makeAddr("keeper"));
    }

    function test_theOwnerAlwaysSweepsEvenWithATriggerNamed() public {
        vm.startPrank(owner);
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(proto)}));
        _f().setAutoYieldTrigger(makeAddr("keeper"));
        _f().autoYield(address(usdc));
        vm.stopPrank();
        assertEq(usdc.balanceOf(_f().getClone(address(proto))), 1_000e6, "naming a trigger does not displace the owner");
    }

    function test_theVaultReportsTheGuardItTrusts() public view {
        assertEq(_f().guard(), BITTY_GUARD, "one shared registry, named in code");
    }

    function test_severalIntentOrdersAreCancelledInOneCall() public {
        vm.prank(owner);
        _f().updateProtocols(_one(address(intent)), _none());

        bytes[] memory uids = new bytes[](2);
        uids[0] = hex"aa";
        uids[1] = hex"bb";
        vm.prank(owner);
        _f().cancelIntentOrders(address(intent), uids);
        assertEq(settlement.invalidatedCount(), 2, "both orders were withdrawn from the book");
    }

    function test_decreasingLiquidityAlsoGrantsTheNftApproval() public {
        PositionNFT nft = new PositionNFT();
        NFTAwareAMM nftAmm = new NFTAwareAMM(address(nft));
        guard.setProtocol(address(nftAmm), AMM_ID);

        vm.startPrank(owner);
        _f().addLiquidity(address(nftAmm), address(usdc), 1e6, address(dai), 1e18, "");
        _f().decreaseLiquidity(address(nftAmm), "");
        _f().claimAMMFees(address(nftAmm), "");
        vm.stopPrank();

        assertTrue(nft.isApprovedForAll(address(vault), _f().getClone(address(nftAmm))), "still approved");
    }

    /**
     * With the allowlist OFF, the guard is still the floor. A token nobody registered is refused even
     * though the owner named no local restrictions at all — "allowlist off" means "fall back to Bitty's
     * curation", never "anything goes".
     */
    function test_anUnregisteredTokenCannotBecomeLiquidityEvenWithTheAllowlistOff() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);
        rnd.mint(address(vault), 100e18);
        assertFalse(_f().allowlistEnabled(), "no local narrowing at all");

        vm.prank(owner);
        vm.expectRevert(NotRegistered.selector);
        _f().addLiquidity(address(amm), address(rnd), 1e18, address(dai), 1e18, "");
    }

    function test_anUnregisteredSecondTokenIsCaughtToo() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);
        rnd.mint(address(vault), 100e18);

        vm.prank(owner);
        vm.expectRevert(NotRegistered.selector);
        _f().addLiquidity(address(amm), address(usdc), 1e6, address(rnd), 1e18, "");
    }
}
