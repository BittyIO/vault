// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {guardAddAssets, guardAddStableCoins, guardAddProtocols} from "../helpers/GuardRegister.sol";
import {GUARD_DEPLOYER} from "../helpers/GuardDeployer.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {VaultLogic} from "../../src/logic/VaultLogic.sol";
import {
    IBittyV1Vault,
    RiskSettings,
    GasBudgetExceeded,
    GasBudgetTooHigh,
    FeeExceedsPerOpCap,
    InvalidRelayedCalldata,
    NotTrustedForwarder,
    InvalidAsset,
    AmountIsZero,
    OnlyImmutablePayableAfterRenounce
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {BITTY_GUARD, BITTY_FORWARDER, BITTY_FEE_COLLECTOR} from "../../src/logic/Constants.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {effectiveAssetManager} from "../helpers/AssetManagerView.sol";

/**
 * @dev Minimal ERC-2771 forwarder: appends the claimed signer to the calldata, exactly as the real
 *      forwarder will. It deliberately does NOT verify a signature — these tests are about what the
 *      vault does with an appended sender, and the signature check belongs to the forwarder's own
 *      tests. That separation also lets us prove the vault ignores a suffix from a caller it does not
 *      trust, which is the property that matters most here.
 */
contract MockForwarder {
    function relay(address target, bytes calldata data, address from) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: msg.value}(abi.encodePacked(data, from));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}

contract GaslessTest is Test {
    BittyV1Vault internal vault;
    MockForwarder internal forwarder;
    WETH internal weth;
    address internal defiFacet;
    address internal guardAddress;
    address internal ownerAddress;
    address internal collector;
    MockERC20 internal usdc;
    address internal keeper;

    // Kept at or below MAX_FEE_PER_OP so one payment can exhaust the day's budget in a single call.
    // Derived from the contract's own ceilings rather than hardcoded, so tightening them does not
    // silently invalidate every fee in this file.
    uint64 internal constant DAILY = VaultLogic.MAX_FEE_PER_OP;

    function setUp() public {
        weth = new WETH();
        deployCodeTo("Gasless.t.sol:MockForwarder", BITTY_FORWARDER);
        forwarder = MockForwarder(BITTY_FORWARDER);
        defiFacet = address(new BittyV1VaultDeFiFacet());
        (keeper,) = makeAddrAndKey("autoYieldKeeper");
        vault = new BittyV1Vault(defiFacet, keeper);
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        deployCodeTo("BittyV1Guard.sol:BittyV1Guard", BITTY_GUARD);
        vm.stopPrank();
        guardAddress = BITTY_GUARD;
        ownerAddress = tx.origin;
        collector = BITTY_FEE_COLLECTOR;
    }

    function _init(address forwarder_, uint64 dailyGasBudget) internal {
        _initWithRisk(forwarder_, dailyGasBudget, RiskSettings(0, 0, 0, 0));
    }

    function _initWithRisk(address forwarder_, uint64 dailyGasBudget, RiskSettings memory risk) internal {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        if (risk.changeTimelock != 0 || risk.newPaymentProtection != 0 || risk.maxSendValue != 0) {
            vm.prank(ownerAddress);
            vault.updatePaymentRisk(
                IBittyV1Owner.PaymentRisk({
                    newPaymentProtection: risk.newPaymentProtection,
                    maxSendValue: risk.maxSendValue,
                    maxSendInterval: risk.maxSendInterval,
                    changeTimelock: risk.changeTimelock
                })
            );
        }
        // Activation never enables relaying, so every test that expects a chargeable relay must turn
        // it on and name the stable coins that may pay for it.
        _enableGasless(dailyGasBudget);
    }

    function _coins() internal view returns (address[] memory coins) {
        coins = new address[](1);
        coins[0] = address(usdc);
    }

    function _enableGasless(uint64 dailyGasBudget) internal {
        address[] memory coins = new address[](1);
        coins[0] = address(usdc) == address(0) ? _ensureStable() : address(usdc);
        vm.prank(ownerAddress);
        vault.setGasless(coins, dailyGasBudget, 0);
    }

    /// Guard-registers a stable coin so it can be listed before any test has funded one.
    function _ensureStable() internal returns (address) {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(usdc);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddStableCoins(address(BittyV1Guard(guardAddress)), toAdd);
        return address(usdc);
    }

    function _fundStable(uint256 amount) internal {
        usdc.mint(address(vault), amount);
    }

    // ============ Sender resolution ============

    function test_RelayedCall_ResolvesToSigner() public {
        _init(address(forwarder), 0);
        address newManager = makeAddr("aiAgent");

        // setAssetManager is owner-only. The forwarder is not the owner, so this can only succeed if
        // the vault resolves the appended signer rather than msg.sender.
        forwarder.relay(address(vault), abi.encodeCall(IBittyV1Owner.setAssetManager, (newManager, 0)), ownerAddress);

        assertEq(effectiveAssetManager(address(vault)), newManager);
    }

    /**
     * The auto-yield keeper is a role like any other, so it must be relayable like any other — it was
     * the last one still forced to hold ETH, because the check read msg.sender raw.
     */
    function test_RelayedAutoYield_ResolvesToTrigger() public {
        _init(address(forwarder), 0);

        address[] memory assetsToSweep = new address[](1);
        assetsToSweep[0] = address(weth);

        // No route is configured for WETH, so autoYield is a no-op — but it only REACHES that no-op if
        // the trigger check resolved the appended signer. Reverting here would be the regression.
        forwarder.relay(address(vault), abi.encodeWithSignature("autoYields(address[])", assetsToSweep), keeper);
    }

    function test_RelayedAutoYield_FromNonTriggerIsRejected() public {
        _init(address(forwarder), 0);
        address[] memory assetsToSweep = new address[](1);
        assetsToSweep[0] = address(weth);

        vm.expectRevert(BittyV1Vault.NotAutoYieldTrigger.selector);
        forwarder.relay(
            address(vault), abi.encodeWithSignature("autoYields(address[])", assetsToSweep), makeAddr("stranger")
        );
    }

    /**
     * The self-call from {receive} is an identity question, not an authorisation one, so it stays on raw
     * msg.sender. An untrusted caller appending the vault's own address must not become the vault.
     */
    function test_SuffixCannotImpersonateTheVaultsSelfCall() public {
        _init(address(forwarder), 0);
        address[] memory assetsToSweep = new address[](1);
        assetsToSweep[0] = address(weth);

        // Relayed, so _msgSender() resolves to the appended vault address — which is deliberately NOT
        // what the self-call branch consults.
        vm.expectRevert(BittyV1Vault.NotAutoYieldTrigger.selector);
        forwarder.relay(address(vault), abi.encodeWithSignature("autoYields(address[])", assetsToSweep), address(vault));
    }

    function test_RelayedCall_FromNonOwnerSignerIsRejected() public {
        _init(address(forwarder), 0);
        address stranger = makeAddr("stranger");

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        forwarder.relay(address(vault), abi.encodeCall(IBittyV1Owner.setAssetManager, (stranger, 0)), stranger);
    }

    /**
     * The property that makes ERC-2771 safe: appending 20 bytes only means something when the call
     * comes from the trusted forwarder. Anyone else appending the owner's address is just sending
     * calldata with garbage on the end, and stays themselves.
     */
    function test_UntrustedCallerCannotSpoofSenderBySuffix() public {
        _init(address(forwarder), 0);
        address attacker = makeAddr("attacker");
        MockForwarder rogue = new MockForwarder();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(rogue)));
        rogue.relay(address(vault), abi.encodeCall(IBittyV1Owner.setAssetManager, (attacker, 0)), ownerAddress);
    }

    /// The direct path must be completely untouched — this is a preference, not a mode.
    function test_DirectCallStillWorksAlongsideRelaying() public {
        _init(address(forwarder), 0);
        address newManager = makeAddr("manager");

        vm.prank(ownerAddress);
        vault.setAssetManager(newManager, 0);

        assertEq(effectiveAssetManager(address(vault)), newManager);
    }

    // ============ payRelayerFee access control ============

    function test_PayRelayerFee_OnlyForwarder() public {
        _init(address(forwarder), DAILY);
        _fundStable(1000_000000);

        vm.prank(ownerAddress);
        vm.expectRevert(NotTrustedForwarder.selector);
        vault.payRelayerFee(address(usdc), 1_000000);
    }

    function test_PayRelayerFee_RejectedWhenNoForwarderConfigured() public {
        _init(address(0), DAILY);
        _fundStable(1000_000000);

        vm.expectRevert(NotTrustedForwarder.selector);
        vault.payRelayerFee(address(usdc), 1_000000);
    }

    function test_PayRelayerFee_RejectsNonStableCoin() public {
        _init(address(forwarder), DAILY);
        MockERC20 random = new MockERC20("Random", "RND", 18);
        random.mint(address(vault), 1000 ether);

        vm.prank(address(forwarder));
        vm.expectRevert(InvalidAsset.selector);
        vault.payRelayerFee(address(random), 1 ether);
    }

    function test_PayRelayerFee_RejectsZeroAmount() public {
        _init(address(forwarder), DAILY);
        _fundStable(1000_000000);

        vm.prank(address(forwarder));
        vm.expectRevert(AmountIsZero.selector);
        vault.payRelayerFee(address(usdc), 0);
    }

    /**
     * The gasless list is independent of the vault's managed assets. A vault that has registered no
     * assets at all can still pay its gas bill, because what matters is the stable coins its owner
     * named in setGasless — not what the vault happens to manage.
     */
    function test_PayRelayerFee_NeedsNoRegisteredAsset() public {
        _init(address(forwarder), DAILY);
        _fundStable(1000_000000);

        assertFalse(vault.isAssetAllowed(address(usdc)), "vault manages nothing");
        assertEq(_coinsOf(vault).length, 1, "but the owner allowed one for gas");

        vm.prank(address(forwarder));
        vault.payRelayerFee(address(usdc), 3_000000);
        assertEq(usdc.balanceOf(collector), 3_000000);
    }

    /// A stable coin the owner did not list cannot be taken, even though the guard knows it.
    function test_PayRelayerFee_RejectsUnlistedStableCoin() public {
        _init(address(forwarder), DAILY);
        _fundStable(1000_000000);

        MockERC20 other = new MockERC20("Tether", "USDT", 6);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(other);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddStableCoins(address(BittyV1Guard(guardAddress)), toAdd);
        other.mint(address(vault), 1000_000000);

        vm.prank(address(forwarder));
        vm.expectRevert(InvalidAsset.selector);
        vault.payRelayerFee(address(other), 3_000000);
    }

    // ============ Daily budget ============

    function test_PayRelayerFee_TransfersAndDecrementsBudget() public {
        _init(address(forwarder), DAILY);
        _fundStable(1000_000000);

        vm.prank(address(forwarder));
        vault.payRelayerFee(address(usdc), 3_000000);

        assertEq(usdc.balanceOf(collector), 3_000000);
        assertEq(vault.gasBudgetRemaining(), (uint256(DAILY) - 3) * 1e18);
    }

    function test_PayRelayerFee_RevertsOverDailyBudget() public {
        _init(address(forwarder), DAILY);
        _fundStable(1000_000000);

        vm.prank(address(forwarder));
        vault.payRelayerFee(address(usdc), uint256(DAILY) * 1e6 - 1e6);

        // 99 + 2 > 100: the cap binds even though the vault holds plenty.
        vm.prank(address(forwarder));
        vm.expectRevert(GasBudgetExceeded.selector);
        vault.payRelayerFee(address(usdc), 2e6);

        assertEq(usdc.balanceOf(collector), uint256(DAILY) * 1e6 - 1e6);
    }

    /**
     * @dev 0 means "no owner preference", so the constant applies — the same convention as
     *      maxFeePerOp. Turning relaying OFF is {disableGasless}, which is its own call now that an
     *      empty coin list means "any guard stable coin" rather than "none".
     */
    function test_BudgetZeroMeansContractDefault() public {
        _init(address(forwarder), 0);
        _fundStable(1000_000000);

        assertEq(_dailyLimitOf(vault), VaultLogic.DAILY_MAX_GAS_BUDGET, "falls back to the constant");

        vm.prank(address(forwarder));
        vault.payRelayerFee(address(usdc), 1);
    }

    function test_DisableGaslessStopsCharging() public {
        _init(address(forwarder), DAILY);
        _fundStable(1000_000000);

        vm.prank(ownerAddress);
        vault.disableGasless();

        assertEq(vault.gasBudgetRemaining(), 0, "off");
        vm.prank(address(forwarder));
        vm.expectRevert(GasBudgetExceeded.selector);
        vault.payRelayerFee(address(usdc), 1);
    }

    function test_BudgetResetsOnNextUtcDay() public {
        _init(address(forwarder), DAILY);
        _fundStable(1000_000000);

        vm.prank(address(forwarder));
        vault.payRelayerFee(address(usdc), uint256(DAILY) * 1e6);
        assertEq(vault.gasBudgetRemaining(), 0);

        vm.warp(block.timestamp + 1 days);
        assertEq(vault.gasBudgetRemaining(), uint256(DAILY) * 1e18, "budget should roll over without any poke");

        vm.prank(address(forwarder));
        vault.payRelayerFee(address(usdc), 10_000000);
        assertEq(usdc.balanceOf(collector), uint256(DAILY) * 1e6 + 10_000000);
    }

    function test_PayRelayerFee_RejectedAfterRenounce() public {
        _init(address(forwarder), DAILY);
        _fundStable(1000_000000);

        // Renouncing requires naming a locked immutable payment as the rescue target, so stand one up.
        IBittyV1Vault.ScheduledPayment[] memory sps = new IBittyV1Vault.ScheduledPayment[](1);
        sps[0] = IBittyV1Vault.ScheduledPayment({
            recipient: makeAddr("rescue"),
            trigger: address(0),
            assetAddress: address(usdc),
            amount: 1_000000,
            remainingPaymentCount: 1,
            startTimestamp: block.timestamp + 1 days,
            paymentInterval: 30 days,
            isImmutable: true,
            payWithInsufficientBalance: false
        });
        vm.prank(ownerAddress);
        uint256[] memory ids = new uint256[](1);
        ids[0] = vault.addScheduledPayment(sps[0]);

        vm.prank(ownerAddress);
        vault.renounceVaultOwnership(ids[0]);

        // Nobody can sign a relayed request for an ownerless vault, so no fee against one is authorised.
        vm.prank(address(forwarder));
        vm.expectRevert(OnlyImmutablePayableAfterRenounce.selector);
        vault.payRelayerFee(address(usdc), 1_000000);
    }

    // ============ setGasBudget ============

    function test_SetGasBudget_OwnerOnly() public {
        _init(address(forwarder), 0);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setGasless(_coins(), DAILY, 0);
    }

    function test_SetGasBudget_EnableIsImmediateWithoutTimelock() public {
        _init(address(forwarder), 0);

        vm.prank(ownerAddress);
        vault.setGasless(_coins(), DAILY, 0);

        // Minimal activation leaves changeTimelock at 0, so the first opt-in takes effect at once —
        // otherwise turning gasless on would itself require an ETH-paid transaction and a wait.
        assertEq(vault.gasBudgetRemaining(), uint256(DAILY) * 1e18);
    }

    function test_SetGasBudget_RaiseIsTimelockedLoweringIsImmediate() public {
        _initWithRisk(address(forwarder), DAILY, RiskSettings(0, 0, 0, 1 days));

        // Lowering protects the user, so it must not be delayed.
        vm.prank(ownerAddress);
        vault.setGasless(_coins(), 10, 0);
        assertEq(vault.gasBudgetRemaining(), 10 * 1e18, "tightening should apply immediately");

        // Raising is the loosening: a phished signature buys a delay, not instant access.
        vm.prank(ownerAddress);
        vault.setGasless(_coins(), VaultLogic.DAILY_MAX_GAS_BUDGET, 0);
        assertEq(vault.gasBudgetRemaining(), 10 * 1e18, "raise must not apply before the timelock");

        vm.warp(block.timestamp + 1 days);
        assertEq(
            vault.gasBudgetRemaining(),
            uint256(VaultLogic.DAILY_MAX_GAS_BUDGET) * 1e18,
            "raise should apply once the timelock elapses"
        );
    }

    /**
     * @dev Clearing the budget to 0 relaxes it back up to DAILY_MAX_GAS_BUDGET, so it is a LOOSENING and
     *      waits out changeTimelock. Without that, a stolen owner key could widen a carefully
     *      tightened budget instantly just by passing 0 — the cheapest possible attack on the one
     *      value bounding what a relayer may take.
     */
    function test_SetGasBudget_ClearingToZeroIsDelayedLikeAnyLoosening() public {
        _initWithRisk(address(forwarder), DAILY, RiskSettings(0, 0, 0, 1 days));
        _fundStable(1000_000000);

        vm.prank(ownerAddress);
        vault.setGasless(_coins(), 0, 0);

        assertEq(_dailyLimitOf(vault), DAILY, "still the tightened value");
        vm.warp(block.timestamp + 1 days);
        assertEq(_dailyLimitOf(vault), VaultLogic.DAILY_MAX_GAS_BUDGET, "and only after the timelock");
    }

    // ============ Fee collector is not caller-supplied ============

    /**
     * The whole point of holding the collector in vault config: a stolen relayer key can overcharge,
     * but every token still lands on the operator's own treasury. If the payee were an argument, the
     * same key would be straight theft of the daily budget from every vault at once.
     */
    function test_ForwarderCannotRedirectTheFee() public {
        _init(address(forwarder), DAILY);
        _fundStable(1000_000000);
        address attacker = makeAddr("attacker");

        vm.prank(address(forwarder));
        vault.payRelayerFee(address(usdc), uint256(DAILY) * 1e6);

        assertEq(usdc.balanceOf(attacker), 0, "no path sends fees anywhere but the configured collector");
        assertEq(usdc.balanceOf(collector), uint256(DAILY) * 1e6);
    }

    // ============ Per-operation ceiling ============

    function test_MaxFeePerOp_BoundsASingleCharge() public {
        _init(address(forwarder), DAILY);
        _fundStable(1000_000000);

        vm.prank(ownerAddress);
        vault.setGasless(_coins(), DAILY, VaultLogic.MAX_FEE_PER_OP / 2);

        // Without this cap a single mis-estimated fee could take the whole day's allowance at once.
        vm.prank(address(forwarder));
        vm.expectRevert(FeeExceedsPerOpCap.selector);
        vault.payRelayerFee(address(usdc), 5_000001);

        vm.prank(address(forwarder));
        vault.payRelayerFee(address(usdc), 5_000000);
        assertEq(usdc.balanceOf(collector), 5_000000);
    }

    /**
     * The footgun this replaced: an unset preference used to mean "no per-charge limit", so the
     * protection did nothing by default. It now falls back to the constant, so a single call can never
     * take the whole daily allowance no matter how the vault is configured.
     */
    function test_UnsetPreferenceFallsBackToTheConstantNotUnlimited() public {
        // A daily budget well above the per-charge constant, so the constant is what binds.
        _init(address(forwarder), VaultLogic.DAILY_MAX_GAS_BUDGET / 2);
        _fundStable(10_000_000000);

        assertEq(_maxFeeOf(vault), VaultLogic.MAX_FEE_PER_OP, "no preference set -> the constant");

        vm.prank(address(forwarder));
        vm.expectRevert(FeeExceedsPerOpCap.selector);
        vault.payRelayerFee(address(usdc), (uint256(VaultLogic.MAX_FEE_PER_OP) + 1) * 1e6);

        vm.prank(address(forwarder));
        vault.payRelayerFee(address(usdc), uint256(VaultLogic.MAX_FEE_PER_OP) * 1e6);
        assertEq(usdc.balanceOf(collector), uint256(VaultLogic.MAX_FEE_PER_OP) * 1e6);
    }

    /**
     * EURC is the case this guards: a legitimate stable coin that is not USD, and more generally a
     * registered stable coin whose decimals are not 6. Charges are normalised by the token's own
     * decimals(), so an 18-decimal fee token is measured in the same whole-token unit as a 6-decimal
     * one instead of the cap silently meaning something 10^12 different.
     */
    function test_CapsAreDecimalsNormalised() public {
        _init(address(forwarder), DAILY);

        MockERC20 eurc18 = new MockERC20("Euro Coin", "EURC", 18);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(eurc18);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddStableCoins(address(BittyV1Guard(guardAddress)), toAdd);
        vm.prank(ownerAddress);
        vault.updateAssets(toAdd, new address[](0));
        eurc18.mint(address(vault), 10_000 ether);
        address[] memory both = new address[](2);
        both[0] = address(usdc);
        both[1] = address(eurc18);
        vm.prank(ownerAddress);
        vault.setGasless(both, DAILY, 0);

        // One whole token over the per-charge constant is refused, even though the raw integer is
        // astronomically larger than the 6-decimal equivalent — the comparison is in whole tokens.
        vm.prank(address(forwarder));
        vm.expectRevert(FeeExceedsPerOpCap.selector);
        vault.payRelayerFee(address(eurc18), (uint256(VaultLogic.MAX_FEE_PER_OP) + 1) * 1 ether);

        uint256 charge = uint256(DAILY) / 2;
        vm.prank(address(forwarder));
        vault.payRelayerFee(address(eurc18), charge * 1 ether);
        assertEq(eurc18.balanceOf(collector), charge * 1 ether);
        // Counted against the daily budget in the same unit as a 6-decimal USDC charge would be.
        assertEq(vault.gasBudgetRemaining(), (uint256(DAILY) - charge) * 1e18);
    }

    /// The owner may tighten below the constant, but never above it.
    function test_OwnerCannotRaisePerOpCapAboveTheConstant() public {
        _init(address(forwarder), DAILY);

        vm.prank(ownerAddress);
        vm.expectRevert(FeeExceedsPerOpCap.selector);
        vault.setGasless(_coins(), DAILY, VaultLogic.MAX_FEE_PER_OP + 1);

        vm.prank(ownerAddress);
        vault.setGasless(_coins(), DAILY, VaultLogic.MAX_FEE_PER_OP);
        assertEq(_maxFeeOf(vault), VaultLogic.MAX_FEE_PER_OP);
    }

    function test_MaxFeePerOp_TighteningImmediateLooseningTimelocked() public {
        _initWithRisk(address(forwarder), DAILY, RiskSettings(0, 0, 0, 1 days));

        vm.prank(ownerAddress);
        vault.setGasless(_coins(), DAILY, VaultLogic.MAX_FEE_PER_OP / 2);
        assertEq(_maxFeeOf(vault), 5, "tightening applies at once");

        vm.prank(ownerAddress);
        vault.setGasless(_coins(), DAILY, VaultLogic.MAX_FEE_PER_OP);
        assertEq(_maxFeeOf(vault), 5, "raising waits out the timelock");

        vm.warp(block.timestamp + 1 days);
        assertEq(_maxFeeOf(vault), VaultLogic.MAX_FEE_PER_OP);
    }

    /// Even after the timelock, relaxing lands on the constant rather than on "no limit".
    function test_MaxFeePerOp_ClearingRelaxesOnlyToTheConstant() public {
        _initWithRisk(address(forwarder), DAILY, RiskSettings(0, 0, 0, 1 days));

        vm.prank(ownerAddress);
        vault.setGasless(_coins(), DAILY, VaultLogic.MAX_FEE_PER_OP / 2);
        vm.prank(ownerAddress);
        vault.setGasless(_coins(), DAILY, 0);
        vm.warp(block.timestamp + 1 days);

        assertEq(_maxFeeOf(vault), VaultLogic.MAX_FEE_PER_OP);
    }

    function test_MaxFeePerOp_ClearingIsTimelocked() public {
        _initWithRisk(address(forwarder), DAILY, RiskSettings(0, 0, 0, 1 days));

        vm.prank(ownerAddress);
        vault.setGasless(_coins(), DAILY, VaultLogic.MAX_FEE_PER_OP / 2);

        // Clearing relaxes the cap back up to the constant, so it is a loosening and waits.
        vm.prank(ownerAddress);
        vault.setGasless(_coins(), DAILY, 0);
        assertEq(_maxFeeOf(vault), 5, "clearing must not take effect instantly");

        vm.warp(block.timestamp + 1 days);
        assertEq(_maxFeeOf(vault), VaultLogic.MAX_FEE_PER_OP);
    }

    // ============ Short relayed calldata ============

    /**
     * With fewer than 24 bytes there is no room for a selector plus the 20-byte suffix, so the facet
     * would dispatch on bytes taken from the appended address itself. That reverts today only because
     * the ABI decoder happens to reject it — this makes the rejection explicit.
     */
    function test_ShortRelayedCalldataIsRejected() public {
        _init(address(forwarder), 0);

        // 3 payload bytes + 20 suffix = 23, one short of a selector plus a sender.
        vm.expectRevert(InvalidRelayedCalldata.selector);
        forwarder.relay(address(vault), hex"112233", ownerAddress);

        // Empty payload is the degenerate case: calldata is nothing but the appended address, whose
        // own leading bytes would otherwise be dispatched as a selector.
        vm.expectRevert(InvalidRelayedCalldata.selector);
        forwarder.relay(address(vault), "", ownerAddress);
    }

    /// A full selector plus the suffix is exactly the 24-byte minimum and must still be accepted.
    function test_MinimumLengthRelayedCallIsAccepted() public {
        _init(address(forwarder), 0);

        // ETHToWETH() takes no arguments, so 4 + 20 is a legitimate relayed call.
        forwarder.relay(address(vault), abi.encodeCall(IBittyV1Vault.ETHToWETH, ()), ownerAddress);
    }

    function test_ShortCalldataFromNonForwarderIsUnaffected() public {
        _init(address(forwarder), 0);

        // Not from the forwarder, so there is no suffix to protect — it just falls through to the
        // facet and fails there as it always did. The guard must not change non-relayed behaviour.
        (bool ok,) = address(vault).call(hex"11223344");
        assertFalse(ok);
    }

    // ============ Hard cap ============

    function test_SetGasBudget_RejectsAboveHardCap() public {
        _init(address(forwarder), 0);

        vm.prank(ownerAddress);
        vm.expectRevert(GasBudgetTooHigh.selector);
        vault.setGasless(_coins(), VaultLogic.DAILY_MAX_GAS_BUDGET + 1, 0);

        // Exactly at the cap is allowed — the bound is inclusive.
        vm.prank(ownerAddress);
        vault.setGasless(_coins(), VaultLogic.DAILY_MAX_GAS_BUDGET, 0);
        assertEq(vault.gasBudgetRemaining(), uint256(VaultLogic.DAILY_MAX_GAS_BUDGET) * 1e18);
    }

    function test_ActivationSeedsTheHardCeiling() public {
        _init(address(forwarder), VaultLogic.DAILY_MAX_GAS_BUDGET);
        assertEq(vault.gasBudgetRemaining(), uint256(VaultLogic.DAILY_MAX_GAS_BUDGET) * 1e18);
    }

    /**
     * The scenario the cap exists for: an owner key compromised into signing the largest budget the
     * type allows. Even then the daily loss is bounded by the cap rather than by uint64.
     */
    function test_CompromisedOwnerKeyCannotUncapTheBudget() public {
        _init(address(forwarder), 0);

        vm.prank(ownerAddress);
        vm.expectRevert(GasBudgetTooHigh.selector);
        vault.setGasless(_coins(), type(uint64).max, 0);

        // The ceiling the owner cannot pass is the contract's, and it still binds.
        assertEq(_dailyLimitOf(vault), VaultLogic.DAILY_MAX_GAS_BUDGET);
    }

    // ============ Views ============

    function test_TrustedForwarderIsReported() public {
        _init(address(forwarder), DAILY);
        assertEq(vault.trustedForwarder(), address(forwarder));
    }

    function test_GasBudgetRemaining_NeverUnderflows() public {
        _initWithRisk(address(forwarder), DAILY, RiskSettings(0, 0, 0, 1 days));
        _fundStable(1000_000000);

        vm.prank(address(forwarder));
        vault.payRelayerFee(address(usdc), uint256(DAILY) * 8e5);

        // Tightening below what has already been spent today must read as 0, not wrap around.
        vm.prank(ownerAddress);
        vault.setGasless(_coins(), DAILY / 2, 0);
        assertEq(vault.gasBudgetRemaining(), 0);
    }

    // Small readers so a single assertion does not have to destructure the whole config tuple.
    function _coinsOf(BittyV1Vault v) internal view returns (address[] memory c) {
        (c,,) = v.gaslessConfig();
    }

    function _dailyLimitOf(BittyV1Vault v) internal view returns (uint256 d) {
        (, d,) = v.gaslessConfig();
    }

    function _maxFeeOf(BittyV1Vault v) internal view returns (uint256 m) {
        (,, m) = v.gaslessConfig();
    }
}
