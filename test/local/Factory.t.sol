// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {
    VaultAlreadyActivated,
    InvalidActivationSignature,
    NotDeployer
} from "../../src/interfaces/IBittyV1VaultFactory.sol";
import {AddressZero} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, BITTY_FEE_COLLECTOR, STABLE_COIN_CATEGORY} from "../../src/logic/Constants.sol";

/**
 * Activation. The vault's address is derived from its OWNER alone, so it can be funded before it
 * exists — which is what makes the pay-in-stable-coin path possible for someone with no ETH at all.
 */
contract FactoryTest is Test {
    BittyV1VaultFactory factory;
    BittyV1Vault impl;
    MockGuard guard;
    MockERC20 usdc;

    uint256 ownerPk = 0xA11CE;
    address owner;
    address weth = makeAddr("weth");
    address constant DEPLOYER = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    function setUp() public {
        owner = vm.addr(ownerPk);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        impl = new BittyV1Vault(address(facet), address(subImpl));

        factory = new BittyV1VaultFactory();
        vm.prank(DEPLOYER, DEPLOYER);
        factory.initialize(address(impl), weth);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), STABLE_COIN_CATEGORY);
    }

    function _sign(address o, address asset, uint256 amount, uint256 pk) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Activation(address owner,address stableCoinAddress,uint256 feeAmount)"), o, asset, amount
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("BittyV1VaultFactory"),
                keccak256("1"),
                block.chainid,
                address(factory)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    // ── deterministic address ─────────────────────────────────────────────────

    /// The address is a function of the owner alone, so it is knowable before anything is deployed.
    function test_addressIsPredictableBeforeActivation() public {
        address predicted = factory.vaultAddress(owner);
        assertEq(predicted.code.length, 0, "nothing there yet");

        vm.prank(owner);
        address deployed = factory.activateVault();
        assertEq(deployed, predicted, "landed exactly where predicted");
    }

    /// One owner, one vault. Ever.
    function test_oneVaultPerOwner() public {
        vm.prank(owner);
        factory.activateVault();
        vm.prank(owner);
        vm.expectRevert(VaultAlreadyActivated.selector);
        factory.activateVault();
    }

    function test_differentOwnersGetDifferentVaults() public {
        address other = makeAddr("other");
        assertTrue(factory.vaultAddress(owner) != factory.vaultAddress(other));
    }

    /// activateVault() is always the CALLER's vault — it cannot be pointed at someone else.
    function test_activateVaultIsAlwaysTheCallersOwn() public {
        vm.prank(owner);
        address v = factory.activateVault();
        assertEq(BittyV1Vault(payable(v)).owner(), owner);
    }

    // ── funded before it exists ───────────────────────────────────────────────

    /**
     * The whole point of the counterfactual address: the fee is deposited to an address with no code,
     * and activation both deploys the vault and pays out of what is already sitting there.
     */
    function test_activationPaysItsFeeFromWhatWasDepositedFirst() public {
        address predicted = factory.vaultAddress(owner);
        usdc.mint(predicted, 100e6); // deposited before the vault exists

        factory.activateVaultByAsset(owner, address(usdc), 2e6, _sign(owner, address(usdc), 2e6, ownerPk));

        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 2e6, "we are repaid for the gas we fronted");
        assertEq(usdc.balanceOf(predicted), 98e6, "the rest stays the owner's");
        assertEq(BittyV1Vault(payable(predicted)).owner(), owner);
    }

    /// Anyone may submit it — the signature is the authority, not the sender.
    function test_anyoneMaySubmitASignedActivation() public {
        address predicted = factory.vaultAddress(owner);
        usdc.mint(predicted, 100e6);
        vm.prank(makeAddr("relayer"));
        factory.activateVaultByAsset(owner, address(usdc), 2e6, _sign(owner, address(usdc), 2e6, ownerPk));
        assertEq(BittyV1Vault(payable(predicted)).owner(), owner);
    }

    // ── signature ─────────────────────────────────────────────────────────────

    function test_forgedActivationSignatureRejected() public {
        (, uint256 wrongPk) = makeAddrAndKey("mallory");
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(owner, address(usdc), 2e6, _sign(owner, address(usdc), 2e6, wrongPk));
    }

    /// The fee is part of what was signed, so a relayer cannot inflate it after the fact.
    function test_aDifferentFeeThanSignedIsRejected() public {
        address predicted = factory.vaultAddress(owner);
        usdc.mint(predicted, 100e6);
        bytes memory sig = _sign(owner, address(usdc), 2e6, ownerPk);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(owner, address(usdc), 50e6, sig);
    }

    /// And so is the coin.
    function test_aDifferentAssetThanSignedIsRejected() public {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        guard.setAsset(address(other), STABLE_COIN_CATEGORY);
        bytes memory sig = _sign(owner, address(usdc), 2e6, ownerPk);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(owner, address(other), 2e6, sig);
    }

    /**
     * No nonce, deliberately: a vault activates exactly once, so a replayed signature simply hits
     * VaultAlreadyActivated. That saves a storage slot on the one path where someone else pays gas.
     */
    function test_replayedActivationHitsAlreadyActivated() public {
        address predicted = factory.vaultAddress(owner);
        usdc.mint(predicted, 100e6);
        bytes memory sig = _sign(owner, address(usdc), 2e6, ownerPk);
        factory.activateVaultByAsset(owner, address(usdc), 2e6, sig);
        vm.expectRevert(VaultAlreadyActivated.selector);
        factory.activateVaultByAsset(owner, address(usdc), 2e6, sig);
    }

    // ── initialize ────────────────────────────────────────────────────────────

    /**
     * Gated on tx.origin, not msg.sender: that is what stops another chain's squatter claiming this
     * factory's deterministic address, at the cost of these calls never being relayable.
     */
    function test_onlyDeployerMayInitialize() public {
        BittyV1VaultFactory fresh = new BittyV1VaultFactory();
        address squatter = makeAddr("squatter");
        vm.prank(squatter, squatter);
        vm.expectRevert(NotDeployer.selector);
        fresh.initialize(address(impl), weth);
    }

    function test_initializeRejectsZeroAddresses() public {
        BittyV1VaultFactory fresh = new BittyV1VaultFactory();
        vm.startPrank(DEPLOYER, DEPLOYER);
        vm.expectRevert(AddressZero.selector);
        fresh.initialize(address(0), weth);
        vm.expectRevert(AddressZero.selector);
        fresh.initialize(address(impl), address(0));
        vm.stopPrank();
    }

    function test_cannotInitializeTwice() public {
        vm.prank(DEPLOYER, DEPLOYER);
        vm.expectRevert();
        factory.initialize(address(impl), weth);
    }
}
