// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {PaymentLogic} from "../../src/logic/PaymentLogic.sol";
import {DeFiLogic} from "../../src/logic/DeFiLogic.sol";
import {GaslessLogic} from "../../src/logic/GaslessLogic.sol";
import {RiskLogic} from "../../src/logic/RiskLogic.sol";
import {ScheduledPaymentLogic} from "../../src/logic/ScheduledPaymentLogic.sol";
import {WhitelistLogic} from "../../src/logic/WhitelistLogic.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {AlreadyInitialized, NotInitialized} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * A bare account: the vault's storage layout and its logic libraries, with none of the initialization
 * an ERC-1967 proxy would have done. Every call here runs the library against genuinely blank storage.
 */
contract UninitializedAccount {
    function initPayments(address weth) external {
        PaymentLogic.initialize(weth);
    }

    function initDeFi(bool allowlistEnabled) external {
        DeFiLogic.initialize(allowlistEnabled);
    }

    function send(address[] memory r, address[] memory a, uint256[] memory m) external {
        PaymentLogic.send(r, a, m);
    }

    function updatePayoutOperator(address account, bool add) external {
        PaymentLogic.updatePayoutOperatorOne(account, add);
    }

    function updateRisk(IBittyV1Owner.PaymentRisk calldata risk) external {
        RiskLogic.updatePaymentRisk(risk);
    }

    function setGasless(address[] calldata assets, uint64 daily, uint64 perOp) external {
        GaslessLogic.setGasless(assets, daily, perOp);
    }

    function disableGasless() external {
        GaslessLogic.disableGasless();
    }

    function payRelayerFee(address asset, uint256 amount) external {
        GaslessLogic.payRelayerFee(asset, amount);
    }

    function enableAllowlist() external {
        DeFiLogic.enableAllowlist();
    }

    function disableAllowlist(uint64 timelock) external {
        DeFiLogic.disableAllowlist(timelock);
    }

    function updateAssets(address[] calldata add, address[] calldata remove) external {
        DeFiLogic.updateAssets(add, remove);
    }

    function deposit(address protocol, address asset, uint256 amount) external {
        DeFiLogic.deposit(protocol, asset, amount);
    }

    function addScheduledPayment(IBittyV1Vault.ScheduledPayment calldata sp) external returns (uint256) {
        return ScheduledPaymentLogic.addScheduledPaymentOne(sp, true, address(this));
    }

    function addWhitelistedRecipient(address recipient, address asset) external returns (uint256) {
        return WhitelistLogic.addWhitelistedRecipientOne(recipient, asset, true, address(this));
    }
}

/**
 * Every logic library refuses to operate on uninitialized storage.
 *
 * On a live account these guards are unreachable — the proxy's `initializer` runs them all exactly once
 * at activation — which is precisely why they are worth pinning here. They are the backstop for the
 * case the initializer is ever bypassed: a botched upgrade, a new account type that forgets a step, or
 * a library reused somewhere it was not designed for. A guard that has never once been observed to fire
 * is a guard nobody knows works.
 */
contract LogicGuardsTest is Test {
    UninitializedAccount account;

    address weth = makeAddr("weth");
    address payee = makeAddr("payee");
    address asset = makeAddr("asset");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        account = new UninitializedAccount();
    }

    function _addr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _amt(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    // ── payments ──────────────────────────────────────────────────────────────

    function test_paymentsRefuseToRunBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.send(_addr(payee), _addr(asset), _amt(1));
    }

    function test_payoutOperatorsCannotBeSetBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.updatePayoutOperator(payee, true);
    }

    function test_scheduledPaymentsRefuseToRunBeforeInitialization() public {
        IBittyV1Vault.ScheduledPayment memory sp = IBittyV1Vault.ScheduledPayment({
            recipient: payee,
            remainingPaymentCount: 1,
            isImmutable: false,
            payWithInsufficientBalance: false,
            trigger: address(0),
            assetAddress: address(0),
            amount: 1,
            startTimestamp: block.timestamp,
            paymentInterval: 0
        });
        vm.expectRevert(NotInitialized.selector);
        account.addScheduledPayment(sp);
    }

    function test_theWhitelistRefusesToRunBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.addWhitelistedRecipient(payee, asset);
    }

    // ── risk and gasless ──────────────────────────────────────────────────────

    function test_riskCannotBeConfiguredBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.updateRisk(
            IBittyV1Owner.PaymentRisk({
                maxSendValue: UNCHANGED,
                maxSendInterval: UNCHANGED,
                newPaymentProtection: UNCHANGED,
                changeTimelock: 1 days
            })
        );
    }

    function test_gaslessCannotBeConfiguredBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.setGasless(new address[](0), 10, 5);
    }

    function test_gaslessCannotBeDisabledBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.disableGasless();
    }

    function test_noRelayerFeeIsPayableBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.payRelayerFee(asset, 1);
    }

    // ── DeFi ──────────────────────────────────────────────────────────────────

    function test_theAllowlistCannotBeTouchedBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.enableAllowlist();

        vm.expectRevert(NotInitialized.selector);
        account.disableAllowlist(0);

        vm.expectRevert(NotInitialized.selector);
        account.updateAssets(_addr(asset), new address[](0));
    }

    function test_nothingCanBeDepositedBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.deposit(makeAddr("protocol"), asset, 1);
    }

    // ── and neither half initializes twice ────────────────────────────────────

    function test_paymentsInitializeExactlyOnce() public {
        account.initPayments(weth);
        vm.expectRevert(AlreadyInitialized.selector);
        account.initPayments(weth);
    }

    function test_defiInitializesExactlyOnce() public {
        account.initDeFi(false);
        vm.expectRevert(AlreadyInitialized.selector);
        account.initDeFi(false);
    }

    function test_initializingOneHalfDoesNotUnlockTheOther() public {
        account.initPayments(weth);
        vm.expectRevert(NotInitialized.selector);
        account.enableAllowlist();
    }

    function test_initializingDeFiDoesNotUnlockPayments() public {
        account.initDeFi(false);
        vm.expectRevert(NotInitialized.selector);
        account.updatePayoutOperator(payee, true);
    }
}
