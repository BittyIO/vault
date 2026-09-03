// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1VaultBootstrap} from "../../src/BittyV1VaultBootstrap.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
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
import {BITTY_GUARD, BITTY_FEE_COLLECTOR} from "../../src/logic/Constants.sol";

/**
 * Activation. The vault's address is derived from its OWNER alone, so it can be funded before it
 * exists — which is what makes the pay-in-stable-coin path possible for someone with no ETH at all.
 */
interface IAllowlistView {
    function allowlistEnabled() external view returns (bool);
    function isAssetAllowed(address asset) external view returns (bool);
}

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
        address boot355 = address(new BittyV1VaultBootstrap());
        vm.prank(DEPLOYER, DEPLOYER);
        factory.initialize(address(impl), weth, boot355);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
    }

    function _sign(address o, address asset, uint256 amount, uint256 pk) internal view returns (bytes memory) {
        return _sign(o, asset, amount, true, pk);
    }

    function _sign(address o, address asset, uint256 amount, bool allowlistEnabled, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Activation(address owner,address stableCoinAddress,uint256 feeAmount,bool allowlistEnabled)"
                ),
                o,
                asset,
                amount,
                allowlistEnabled
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
        address deployed = factory.activateVault(true);
        assertEq(deployed, predicted, "landed exactly where predicted");
    }

    /// One owner, one vault. Ever.
    function test_oneVaultPerOwner() public {
        vm.prank(owner);
        factory.activateVault(true);
        vm.prank(owner);
        vm.expectRevert(VaultAlreadyActivated.selector);
        factory.activateVault(true);
    }

    function test_differentOwnersGetDifferentVaults() public {
        address other = makeAddr("other");
        assertTrue(factory.vaultAddress(owner) != factory.vaultAddress(other));
    }

    /// activateVault() is always the CALLER's vault — it cannot be pointed at someone else.
    function test_activateVaultIsAlwaysTheCallersOwn() public {
        vm.prank(owner);
        address v = factory.activateVault(true);
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

        factory.activateVaultByAsset(owner, address(usdc), 2e6, true, _sign(owner, address(usdc), 2e6, ownerPk));

        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 2e6, "we are repaid for the gas we fronted");
        assertEq(usdc.balanceOf(predicted), 98e6, "the rest stays the owner's");
        assertEq(BittyV1Vault(payable(predicted)).owner(), owner);
    }

    /// Anyone may submit it — the signature is the authority, not the sender.
    function test_anyoneMaySubmitASignedActivation() public {
        address predicted = factory.vaultAddress(owner);
        usdc.mint(predicted, 100e6);
        vm.prank(makeAddr("relayer"));
        factory.activateVaultByAsset(owner, address(usdc), 2e6, true, _sign(owner, address(usdc), 2e6, ownerPk));
        assertEq(BittyV1Vault(payable(predicted)).owner(), owner);
    }

    // ── signature ─────────────────────────────────────────────────────────────

    function test_forgedActivationSignatureRejected() public {
        (, uint256 wrongPk) = makeAddrAndKey("mallory");
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(owner, address(usdc), 2e6, true, _sign(owner, address(usdc), 2e6, wrongPk));
    }

    /// The fee is part of what was signed, so a relayer cannot inflate it after the fact.
    function test_aDifferentFeeThanSignedIsRejected() public {
        address predicted = factory.vaultAddress(owner);
        usdc.mint(predicted, 100e6);
        bytes memory sig = _sign(owner, address(usdc), 2e6, ownerPk);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(owner, address(usdc), 50e6, true, sig);
    }

    /// And so is the coin.
    function test_aDifferentAssetThanSignedIsRejected() public {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        guard.setAsset(address(other), ASSET_STABLE_COIN);
        bytes memory sig = _sign(owner, address(usdc), 2e6, ownerPk);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(owner, address(other), 2e6, true, sig);
    }

    /**
     * No nonce, deliberately: a vault activates exactly once, so a replayed signature simply hits
     * VaultAlreadyActivated. That saves a storage slot on the one path where someone else pays gas.
     */
    function test_replayedActivationHitsAlreadyActivated() public {
        address predicted = factory.vaultAddress(owner);
        usdc.mint(predicted, 100e6);
        bytes memory sig = _sign(owner, address(usdc), 2e6, ownerPk);
        factory.activateVaultByAsset(owner, address(usdc), 2e6, true, sig);
        vm.expectRevert(VaultAlreadyActivated.selector);
        factory.activateVaultByAsset(owner, address(usdc), 2e6, true, sig);
    }

    // ── initialize ────────────────────────────────────────────────────────────

    /**
     * Gated on tx.origin, not msg.sender: that is what stops another chain's squatter claiming this
     * factory's deterministic address, at the cost of these calls never being relayable.
     */
    function test_onlyDeployerMayInitialize() public {
        address boot = address(new BittyV1VaultBootstrap());
        BittyV1VaultFactory fresh = new BittyV1VaultFactory();
        address squatter = makeAddr("squatter");
        vm.prank(squatter, squatter);
        vm.expectRevert(NotDeployer.selector);
        fresh.initialize(address(impl), weth, boot);
    }

    function test_initializeRejectsZeroAddresses() public {
        address boot = address(new BittyV1VaultBootstrap());
        BittyV1VaultFactory fresh = new BittyV1VaultFactory();
        vm.startPrank(DEPLOYER, DEPLOYER);
        vm.expectRevert(AddressZero.selector);
        fresh.initialize(address(0), weth, boot);
        vm.expectRevert(AddressZero.selector);
        fresh.initialize(address(impl), address(0), boot);
        vm.stopPrank();
    }

    /// The setter guards the same zero it guards at initialize: a zero implementation would leave the
    /// factory minting vaults that upgrade straight off the bootstrap into nothing.
    function test_setVaultImplementationRejectsZero() public {
        vm.prank(DEPLOYER, DEPLOYER);
        vm.expectRevert(AddressZero.selector);
        factory.setVaultImplementation(address(0));
    }

    /// Activating with WETH as the fee asset makes the vault list the SAME asset twice - once as the
    /// activation asset, once as the wrapped-native default. The second listing is a no-op rather than
    /// a revert or a duplicate entry.
    function test_activatingWithWethAsTheFeeAssetListsItOnce() public {
        BittyV1VaultFactory fresh = new BittyV1VaultFactory();
        address boot = address(new BittyV1VaultBootstrap());
        vm.prank(DEPLOYER, DEPLOYER);
        fresh.initialize(address(impl), address(usdc), boot);
        // The activation signature is bound to the verifying contract, and _sign reads this field.
        factory = fresh;

        usdc.mint(fresh.vaultAddress(owner), 100e6);
        address v =
            fresh.activateVaultByAsset(owner, address(usdc), 2e6, true, _sign(owner, address(usdc), 2e6, ownerPk));

        assertTrue(IAllowlistView(v).allowlistEnabled(), "allowlist should be on");
        assertTrue(IAllowlistView(v).isAssetAllowed(address(usdc)), "the fee asset is listed");
    }

    /// The bootstrap authorises exactly ONE upgrade - the factory's, before the vault has an owner.
    /// A proxy still sitting on it with an owner already set is a claimed vault, and must refuse.
    function test_bootstrapRefusesToMoveAClaimedVault() public {
        address proxy = address(new ERC1967Proxy(address(new BittyV1VaultBootstrap()), ""));
        // OwnableUpgradeable's ERC-7201 slot, which is what the bootstrap reads.
        vm.store(
            proxy, 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300, bytes32(uint256(uint160(owner)))
        );

        vm.expectRevert(VaultAlreadyActivated.selector);
        UUPSUpgradeable(proxy).upgradeToAndCall(address(impl), "");
    }

    function test_cannotInitializeTwice() public {
        address boot = address(new BittyV1VaultBootstrap());
        vm.prank(DEPLOYER, DEPLOYER);
        vm.expectRevert();
        factory.initialize(address(impl), weth, boot);
    }

    /**
     * The choice is the OWNER's, so it lives inside the signed struct. A relayer that could pass its
     * own flag would decide whether someone else's vault starts restricted - the fee is protected
     * the same way and for the same reason.
     */
    function test_allowlistChoiceIsBoundToTheSignature() public {
        usdc.mint(factory.vaultAddress(owner), 2e6);
        bytes memory signedForOn = _sign(owner, address(usdc), 2e6, true, ownerPk);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(owner, address(usdc), 2e6, false, signedForOn);
    }

    /// Activating with the allowlist OFF leaves the guard's catalog as the only gate.
    function test_activatingWithTheAllowlistOff() public {
        address v = factory.activateVault(false);
        assertFalse(IAllowlistView(v).allowlistEnabled(), "allowlist should be off");
        assertTrue(IAllowlistView(v).isAssetAllowed(address(usdc)), "guard-registered asset must pass");
    }

    /// ...and ON restricts to what the vault itself has listed.
    function test_activatingWithTheAllowlistOn() public {
        address v = factory.activateVault(true);
        assertTrue(IAllowlistView(v).allowlistEnabled(), "allowlist should be on");
        assertFalse(IAllowlistView(v).isAssetAllowed(address(usdc)), "unlisted asset must not pass");
    }

    /**
     * The whole point of the bootstrap: a vault's address must not move when a new build ships.
     *
     * Before this, the proxy was born pointing at the CURRENT implementation, so that address was in
     * the proxy's init code and therefore in the CREATE2 hash - every release relocated every owner's
     * vault, including counterfactual ones people had already funded.
     */
    function test_vaultAddressSurvivesAnImplementationChange() public {
        address predictedBefore = factory.vaultAddress(owner);

        BittyV1VaultDeFiFacet facet2 = new BittyV1VaultDeFiFacet();
        BittyV1Vault newImpl = new BittyV1Vault(address(facet2), address(new BittyV1SubVault(address(facet2))));
        vm.prank(DEPLOYER, DEPLOYER);
        factory.setVaultImplementation(address(newImpl));

        assertEq(factory.vaultAddress(owner), predictedBefore, "vault address moved with the implementation");

        // ...and the vault actually deployed there runs the NEW build.
        vm.prank(owner);
        address deployed = factory.activateVault(true);
        assertEq(deployed, predictedBefore, "deployed somewhere other than predicted");
        assertEq(_implOf(deployed), address(newImpl), "not upgraded off the bootstrap");
    }

    /// A vault leaves the bootstrap in the same transaction it is created in.
    function test_vaultDoesNotStayOnTheBootstrap() public {
        vm.prank(owner);
        address v = factory.activateVault(true);
        assertEq(_implOf(v), address(impl), "should be on the real implementation");
        assertTrue(_implOf(v) != factory.bootstrapImplementation(), "still on the bootstrap");
    }

    /// Only the deployer may point new vaults at a different build.
    function test_onlyDeployerMaySetVaultImplementation() public {
        vm.prank(makeAddr("stranger"), makeAddr("stranger"));
        vm.expectRevert(NotDeployer.selector);
        factory.setVaultImplementation(address(impl));
    }

    function _implOf(address proxy) internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, slot))));
    }
}
