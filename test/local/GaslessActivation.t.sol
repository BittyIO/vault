// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {STABLE_COIN_CATEGORY} from "../helpers/GuardRegister.sol";
import {guardAddAssets, guardAddStableCoins, guardAddProtocols} from "../helpers/GuardRegister.sol";
import {GUARD_DEPLOYER} from "../helpers/GuardDeployer.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {InvalidActivationSignature, VaultAlreadyActivated} from "../../src/interfaces/IBittyV1VaultFactory.sol";
import {FeeExceedsPerOpCap, InsufficientBalance} from "../../src/interfaces/IBittyV1Vault.sol";
import {VaultLogic} from "../../src/logic/VaultLogic.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {BITTY_GUARD, BITTY_FORWARDER, BITTY_FEE_COLLECTOR} from "../../src/logic/Constants.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

contract GaslessActivationTest is Test {
    address internal constant AUTO_YIELD_KEEPER = address(0xA07E1D);

    BittyV1VaultFactory internal factory;
    BittyV1Guard internal guard;
    WETH internal weth;
    MockERC20 internal usdc;
    MockERC20 internal usdt;

    address internal collector = BITTY_FEE_COLLECTOR;
    address internal relayer = makeAddr("relayer");
    address internal forwarder = BITTY_FORWARDER;
    address internal alice;
    uint256 internal pk;

    bytes32 constant TYPEHASH = keccak256("Activation(address owner,address stableCoinAddress,uint256 feeAmount)");
    bytes32 constant GASLESS_TYPEHASH =
        keccak256("ActivationGasless(address owner,address stableCoinAddress,uint256 feeAmount)");

    function setUp() public {
        (alice, pk) = makeAddrAndKey("alice");
        weth = new WETH();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        deployCodeTo("BittyV1Guard.sol:BittyV1Guard", BITTY_GUARD);
        vm.stopPrank();
        guard = BittyV1Guard(BITTY_GUARD);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        address[] memory stables = new address[](2);
        stables[0] = address(usdc);
        stables[1] = address(usdt);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddStableCoins(address(guard), stables);

        factory = new BittyV1VaultFactory();
        // Deploy before the prank: a `new` expression inside the argument list is a CREATE that would
        // consume it, leaving initialize to run with the wrong tx.origin.
        address impl = address(new BittyV1Vault(address(new BittyV1VaultDeFiFacet()), address(0xA07E1D)));
        address facet = address(new BittyV1VaultDeFiFacet());
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(impl, address(weth));
    }

    function _sign(uint256 fee) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, alice, address(usdc), fee));
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BittyV1VaultFactory")),
                keccak256(bytes("1")),
                block.chainid,
                address(factory)
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(rr, ss, v);
    }

    function _activate(uint256 fee) internal {
        factory.activateVaultByAsset(alice, address(usdc), fee, _sign(fee));
    }

    /**
     * The whole point: an owner who has never held ETH ends up with a funded, working vault.
     */
    function test_OwnerWithNoEthGetsAVault() public {
        address predicted = factory.vaultAddress(alice);
        usdc.mint(predicted, 500_000000); // deposited straight to the code-less address

        assertEq(alice.balance, 0, "the owner never holds ETH at any point");
        assertEq(predicted.code.length, 0, "and the vault does not exist yet");

        vm.prank(relayer);
        _activate(2_000000);

        assertGt(predicted.code.length, 0, "vault deployed");
        assertEq(BittyV1Vault(payable(predicted)).owner(), alice);
        assertEq(usdc.balanceOf(collector), 2_000000, "we are repaid for the gas we fronted");
        assertEq(usdc.balanceOf(predicted), 498_000000, "the rest stays the owner's");
        assertEq(alice.balance, 0);
    }

    /**
     * Every vault activates at the hard ceiling, so the owner's very next action is already gasless.
     */
    /**
     * The forwarder and collector are wired from factory config, so an owner can never point at
     * someone else's — and relaying is on from birth, because a user with no ETH cannot otherwise turn
     * on the thing that lets them transact without ETH.
     */
    function test_ActivationWiresBittyAndLeavesRelayingOn() public {
        address predicted = factory.vaultAddress(alice);
        usdc.mint(predicted, 100_000000);
        vm.prank(relayer);
        _activate(2_000000);

        BittyV1Vault v = BittyV1Vault(payable(predicted));
        assertEq(v.trustedForwarder(), forwarder, "Bitty's forwarder is wired by the factory");
        assertEq(
            v.gasBudgetRemaining(),
            uint256(VaultLogic.DAILY_MAX_GAS_BUDGET) * 1e18,
            "relayable from birth, at the contract default"
        );
        // The coin list starts EMPTY, and empty means "any asset the guard registers" rather than
        // "none". Reading it as "none" would make a fresh vault unrelayable until the owner spent
        // their own ETH on a setGasless call — the one thing gasless exists to avoid. Proved by
        // charging in USDT, which had nothing to do with activation.
        assertEq(_coinsOf(v).length, 0, "nothing narrowed at birth");
        usdt.mint(predicted, 5_000000);
        vm.prank(forwarder);
        v.payRelayerFee(address(usdt), 1_000000);
        assertEq(usdt.balanceOf(collector), 1_000000, "any registered asset may pay from birth");
    }

    /**
     * The owner narrows it afterwards, naming what may pay for it.
     */
    function test_OwnerEnablesGaslessAfterActivation() public {
        address predicted = factory.vaultAddress(alice);
        usdc.mint(predicted, 100_000000);
        vm.prank(relayer);
        _activate(2_000000);

        BittyV1Vault v = BittyV1Vault(payable(predicted));
        address[] memory coins = new address[](1);
        coins[0] = address(usdc);
        vm.prank(alice);
        v.setGasless(coins, 100, 0);

        assertEq(v.gasBudgetRemaining(), 100 * 1e18);
        assertEq(_coinsOf(v)[0], address(usdc));
    }

    function test_ActivationWithoutFee() public {
        address predicted = factory.vaultAddress(alice);
        usdc.mint(predicted, 10_000000);
        vm.prank(relayer);
        _activate(0);

        assertEq(usdc.balanceOf(collector), 0);
        assertEq(usdc.balanceOf(predicted), 10_000000);
    }

    function _coins() internal view returns (address[] memory c) {
        c = new address[](1);
        c[0] = address(usdc);
    }

    function _signGasless(uint256 fee) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(GASLESS_TYPEHASH, alice, address(usdc), fee));
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BittyV1VaultFactory")),
                keccak256(bytes("1")),
                block.chainid,
                address(factory)
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(rr, ss, v);
    }

    function test_ActivationLeavesRelayingOnAtContractDefaults() public {
        address predicted = factory.vaultAddress(alice);
        usdc.mint(predicted, 100_000000);

        vm.prank(relayer);
        _activate(2_000000);

        BittyV1Vault v = BittyV1Vault(payable(predicted));
        assertEq(v.owner(), alice);
        assertEq(usdc.balanceOf(collector), 2_000000, "activation still charges its fee");
        // Contract defaults, not owner-chosen terms: activation should not charge for settings most
        // owners never change, and setGasless is there for the ones who do.
        assertEq(
            v.gasBudgetRemaining(), uint256(VaultLogic.DAILY_MAX_GAS_BUDGET) * 1e18, "relaying on at the default budget"
        );
        assertEq(_maxFeeOf(v), VaultLogic.MAX_FEE_PER_OP, "default per-op ceiling");
        // Empty, and empty means every registered stable coin — including the one that paid the
        // activation fee, which is deliberately NOT recorded as the vault's chosen coin. Seeding it
        // would narrow the vault to whatever happened to pay, which is the opposite of the intent.
        assertEq(_coinsOf(v).length, 0, "activation narrows nothing");
        assertEq(guard.assetCategory(address(usdc)), STABLE_COIN_CATEGORY, "usdc is a stable coin asset");
    }

    // ============ Authorisation ============

    function test_ForgedSignatureRejected() public {
        usdc.mint(factory.vaultAddress(alice), 100_000000);
        (, uint256 wrongPk) = makeAddrAndKey("mallory");
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(wrongPk, keccak256("whatever"));
        bytes memory forged = abi.encodePacked(rr, ss, v);

        vm.prank(relayer);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(alice, address(usdc), 2_000000, forged);
    }

    /**
     * Tampering with any signed field — here the fee — invalidates the signature.
     */
    function test_TamperedFeeRejected() public {
        usdc.mint(factory.vaultAddress(alice), 100_000000);
        bytes memory sig = _sign(2_000000);

        vm.prank(relayer);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(alice, address(usdc), 90_000000, sig);
    }

    /**
     * No nonce is stored: a vault activates once, so a replay just hits VaultAlreadyActivated.
     */
    function test_ReplayHitsAlreadyActivated() public {
        usdc.mint(factory.vaultAddress(alice), 100_000000);
        vm.prank(relayer);
        _activate(2_000000);

        vm.prank(relayer);
        vm.expectRevert(VaultAlreadyActivated.selector);
        _activate(2_000000);
    }

    // ============ Tampering with unsigned fields ============

    /**
     * A valid signature is public once submitted, so anyone can resubmit it. The signature covers the
     * owner, assets, fee token, fee amount and deadline; every other setting must be forced to the
     * minimal configuration, or whoever relays could choose settings the owner never agreed to.
     *
     * The auto-yield trigger used to be reachable here and is now simply not a parameter — activation
     * cannot configure one at all, so there is nothing left to tamper with. {setAutoYieldings} is the
     * owner's own call, made later.
     */
    function test_ActivationCannotConfigureAutoYield() public {
        usdc.mint(factory.vaultAddress(alice), 100_000000);
        vm.prank(makeAddr("attacker"));
        _activate(2_000000);

        BittyV1Vault v = BittyV1Vault(payable(factory.vaultAddress(alice)));
        address[] memory one = new address[](1);
        one[0] = address(usdc);
        address[] memory protocols = v.getAutoYieldings(one);
        assertEq(protocols[0], address(0), "and no route either");
    }

    /**
     * Anyone may submit a valid signature — that is the point — and the result is what the owner signed.
     */
    function test_AnyoneMaySubmitAValidSignature() public {
        usdc.mint(factory.vaultAddress(alice), 100_000000);
        vm.prank(makeAddr("randomStranger"));
        _activate(2_000000);

        assertEq(BittyV1Vault(payable(factory.vaultAddress(alice))).owner(), alice);
        assertEq(usdc.balanceOf(collector), 2_000000, "the fee still goes to the configured collector");
    }

    /**
     * A vault can only ever be created for an address that produced a signature, so it cannot be
     * activated for a dead address whose owner could never act. The one way that could break is
     * ecrecover returning address(0) on a malformed signature and matching an owner of address(0) —
     * OZ guards it by checking the recover error, and this pins that we depend on that guard.
     */
    function test_CannotActivateForZeroAddress() public {
        vm.prank(relayer);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(address(0), address(usdc), 0, hex"deadbeef");

        // Even a well-formed 65-byte signature that recovers to nothing must not pass.
        vm.prank(relayer);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(address(0), address(usdc), 0, new bytes(65));
    }

    /**
     * And a random third party cannot be made an owner: there is no signature for them to have made.
     */
    function test_CannotActivateForAnAddressThatDidNotSign() public {
        address stranger = makeAddr("strangerWhoNeverSigned");
        usdc.mint(factory.vaultAddress(stranger), 100_000000);

        vm.prank(relayer);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(stranger, address(usdc), 2_000000, _sign(2_000000));
    }

    // ============ Fee bounds ============

    /**
     * Even with a valid signature, the contract refuses a fee above the hard constant.
     */
    function test_FeeAboveHardCapRejected() public {
        usdc.mint(factory.vaultAddress(alice), 10_000_000000);
        vm.prank(relayer);
        vm.expectRevert(FeeExceedsPerOpCap.selector);
        _activate((uint256(VaultLogic.MAX_FEE_PER_OP) + 1) * 1e6);
    }

    /**
     * A signature with no deposit behind it is inert rather than dangerous.
     */
    function test_UnfundedVaultCannotBeActivatedForAFee() public {
        vm.prank(relayer);
        vm.expectRevert(InsufficientBalance.selector);
        _activate(2_000000);
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
