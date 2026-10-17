// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {PaymentLogic} from "../../src/logic/PaymentLogic.sol";
import {DeFiLogic} from "../../src/logic/DeFiLogic.sol";
import {StableCoinAsGasLogic} from "../../src/logic/StableCoinAsGasLogic.sol";
import {RiskLogic} from "../../src/logic/RiskLogic.sol";
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
    function initialize(address gasWrapped) external {
        PaymentLogic.initialize(gasWrapped, false);
    }

    function send(address[] memory r, address[] memory a, uint256[] memory m) external {
        PaymentLogic.send(r, a, m);
    }

    function updateRisk(IBittyV1Owner.RiskSettings calldata risk) external {
        RiskLogic.updateRisk(risk);
    }

    function setStableCoinAsGas(address[] calldata assets, uint64 daily, uint64 perOp) external {
        StableCoinAsGasLogic.setStableCoinAsGas(assets, daily, perOp);
    }

    function disableStableCoinAsGas() external {
        StableCoinAsGasLogic.disableStableCoinAsGas();
    }

    function payRelayerFee(address asset, uint256 amount) external {
        StableCoinAsGasLogic.payRelayerFee(asset, amount);
    }

    function activateOwnAllowList() external {
        DeFiLogic.activateOwnAllowList();
    }

    function deactivateOwnAllowList() external {
        DeFiLogic.deactivateOwnAllowList();
    }

    function updateAssets(address[] calldata add, address[] calldata remove) external {
        DeFiLogic.updateAssets(add, remove);
    }

    function deposit(address protocol, address asset, uint256 amount) external {
        DeFiLogic.deposit(protocol, asset, amount);
    }

    function addWhitelistedRecipient(address recipient) external returns (uint256) {
        return WhitelistLogic.addWhitelistedRecipientOne(recipient);
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

    address gasWrapped = makeAddr("gasWrapped");
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

    function test_theWhitelistRefusesToRunBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.addWhitelistedRecipient(payee);
    }

    // ── risk and stablecoin-as-gas ──────────────────────────────────────────────────────

    function test_riskCannotBeConfiguredBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.updateRisk(
            IBittyV1Owner.RiskSettings({
                timelock: 1 days, sendDailyAllowance: UNCHANGED, marketTradeDailyLossAllowance: UNCHANGED
            })
        );
    }

    function test_stableCoinAsGasCannotBeConfiguredBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.setStableCoinAsGas(new address[](0), 10, 5);
    }

    function test_stableCoinAsGasCannotBeDisabledBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.disableStableCoinAsGas();
    }

    function test_noRelayerFeeIsPayableBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.payRelayerFee(asset, 1);
    }

    // ── DeFi ──────────────────────────────────────────────────────────────────

    function test_theAllowlistCannotBeTouchedBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.activateOwnAllowList();

        vm.expectRevert(NotInitialized.selector);
        account.deactivateOwnAllowList();

        vm.expectRevert(NotInitialized.selector);
        account.updateAssets(_addr(asset), new address[](0));
    }

    function test_nothingCanBeDepositedBeforeInitialization() public {
        vm.expectRevert(NotInitialized.selector);
        account.deposit(makeAddr("protocol"), asset, 1);
    }

    // ── and one initialization, exactly once, for both halves ─────────────────

    /**
     * Payments and DeFi share one initialised flag — it sits in the slot the payment side writes
     * anyway — so there is no state in which one half is live and the other is not.
     */
    function test_theAccountInitializesExactlyOnce() public {
        account.initialize(gasWrapped);
        vm.expectRevert(AlreadyInitialized.selector);
        account.initialize(gasWrapped);
    }

    function test_oneInitializationUnlocksBothHalves() public {
        account.initialize(gasWrapped);
        account.activateOwnAllowList();
        account.deactivateOwnAllowList();
    }
}
