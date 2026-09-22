// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1VaultBootstrap} from "../../src/BittyV1VaultBootstrap.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ASSET_STABLE_COIN, IMPLEMENTATION_VAULT} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {
    BittyV1VaultFactoryBootstrap,
    NotOwner as FactoryBootstrapNotOwner
} from "../../src/BittyV1VaultFactoryBootstrap.sol";
import {VaultAlreadyActivated, InvalidActivationSignature} from "../../src/interfaces/IBittyV1VaultFactory.sol";
import {
    BITTY_GUARD,
    BITTY_FEE_COLLECTOR,
    BITTY_VAULT_BOOTSTRAP,
    CFG_GAS_WRAPPED,
    CFG_OWNER
} from "../../src/logic/Constants.sol";

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
    address gasWrapped = makeAddr("gasWrapped");

    function setUp() public {
        owner = vm.addr(ownerPk);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        impl = new BittyV1Vault(address(facet), address(subImpl));

        factory = new BittyV1VaultFactory();
        // deployCodeTo (not etch) so the bootstrap's UUPS __self immutable resolves to this constant.
        deployCodeTo("BittyV1VaultBootstrap.sol:BittyV1VaultBootstrap", BITTY_VAULT_BOOTSTRAP);
        guard.setLatestImpl(IMPLEMENTATION_VAULT, address(impl));
        guard.setConfigAddress(CFG_GAS_WRAPPED, gasWrapped);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
    }

    function _noCalls() internal pure returns (bytes[] memory) {
        return new bytes[](0);
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
                    "Activation(address owner,address stableCoinAddress,uint256 feeAmount,bool allowlistEnabled,bytes[] calls)"
                ),
                o,
                asset,
                amount,
                allowlistEnabled,
                keccak256("")
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
        address deployed = factory.activateVault(true, _noCalls());
        assertEq(deployed, predicted, "landed exactly where predicted");
    }

    /// One owner, one vault. Ever.
    function test_oneVaultPerOwner() public {
        vm.prank(owner);
        factory.activateVault(true, _noCalls());
        vm.prank(owner);
        vm.expectRevert(VaultAlreadyActivated.selector);
        factory.activateVault(true, _noCalls());
    }

    function test_differentOwnersGetDifferentVaults() public {
        address other = makeAddr("other");
        assertTrue(factory.vaultAddress(owner) != factory.vaultAddress(other));
    }

    /// activateVault() is always the CALLER's vault — it cannot be pointed at someone else.
    function test_activateVaultIsAlwaysTheCallersOwn() public {
        vm.prank(owner);
        address v = factory.activateVault(true, _noCalls());
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

        factory.activateVaultByAsset(
            owner, address(usdc), 2e6, true, _noCalls(), _sign(owner, address(usdc), 2e6, ownerPk)
        );

        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 2e6, "we are repaid for the gas we fronted");
        assertEq(usdc.balanceOf(predicted), 98e6, "the rest stays the owner's");
        assertEq(BittyV1Vault(payable(predicted)).owner(), owner);
    }

    /// Anyone may submit it — the signature is the authority, not the sender.
    function test_anyoneMaySubmitASignedActivation() public {
        address predicted = factory.vaultAddress(owner);
        usdc.mint(predicted, 100e6);
        vm.prank(makeAddr("relayer"));
        factory.activateVaultByAsset(
            owner, address(usdc), 2e6, true, _noCalls(), _sign(owner, address(usdc), 2e6, ownerPk)
        );
        assertEq(BittyV1Vault(payable(predicted)).owner(), owner);
    }

    // ── signature ─────────────────────────────────────────────────────────────

    function test_forgedActivationSignatureRejected() public {
        (, uint256 wrongPk) = makeAddrAndKey("mallory");
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(
            owner, address(usdc), 2e6, true, _noCalls(), _sign(owner, address(usdc), 2e6, wrongPk)
        );
    }

    /// The fee is part of what was signed, so a relayer cannot inflate it after the fact.
    function test_aDifferentFeeThanSignedIsRejected() public {
        address predicted = factory.vaultAddress(owner);
        usdc.mint(predicted, 100e6);
        bytes memory sig = _sign(owner, address(usdc), 2e6, ownerPk);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(owner, address(usdc), 50e6, true, _noCalls(), sig);
    }

    /// And so is the coin.
    function test_aDifferentAssetThanSignedIsRejected() public {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        guard.setAsset(address(other), ASSET_STABLE_COIN);
        bytes memory sig = _sign(owner, address(usdc), 2e6, ownerPk);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(owner, address(other), 2e6, true, _noCalls(), sig);
    }

    /**
     * No nonce, deliberately: a vault activates exactly once, so a replayed signature simply hits
     * VaultAlreadyActivated. That saves a storage slot on the one path where someone else pays gas.
     */
    function test_replayedActivationHitsAlreadyActivated() public {
        address predicted = factory.vaultAddress(owner);
        usdc.mint(predicted, 100e6);
        bytes memory sig = _sign(owner, address(usdc), 2e6, ownerPk);
        factory.activateVaultByAsset(owner, address(usdc), 2e6, true, _noCalls(), sig);
        vm.expectRevert(VaultAlreadyActivated.selector);
        factory.activateVaultByAsset(owner, address(usdc), 2e6, true, _noCalls(), sig);
    }

    // ── initialize ────────────────────────────────────────────────────────────

    /// The wrapped-gas token comes from the guard now: activation reverts if the chain hasn't set it.
    function test_activationRevertsWhenGasWrappedUnset() public {
        guard.setConfigAddress(CFG_GAS_WRAPPED, address(0)); // simulate an unconfigured chain
        vm.prank(makeAddr("someone"));
        vm.expectRevert(); // vault initialize hits AddressZero on a zero wrapped-gas token
        factory.activateVault(true, _noCalls());
    }

    /// Activating with WETH as the fee asset makes the vault list the SAME asset twice - once as the
    /// activation asset, once as the wrapped-native default. The second listing is a no-op rather than
    /// a revert or a duplicate entry.
    function test_activatingWithWethAsTheFeeAssetListsItOnce() public {
        guard.setConfigAddress(CFG_GAS_WRAPPED, address(usdc)); // wrapped-gas == the fee asset for this case
        usdc.mint(factory.vaultAddress(owner), 100e6);
        address v = factory.activateVaultByAsset(
            owner, address(usdc), 2e6, true, _noCalls(), _sign(owner, address(usdc), 2e6, ownerPk)
        );

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

    /**
     * The choice is the OWNER's, so it lives inside the signed struct. A relayer that could pass its
     * own flag would decide whether someone else's vault starts restricted - the fee is protected
     * the same way and for the same reason.
     */
    function test_allowlistChoiceIsBoundToTheSignature() public {
        usdc.mint(factory.vaultAddress(owner), 2e6);
        bytes memory signedForOn = _sign(owner, address(usdc), 2e6, true, ownerPk);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(owner, address(usdc), 2e6, false, _noCalls(), signedForOn);
    }

    /// Activating with the allowlist OFF leaves the guard's catalog as the only gate.
    function test_activatingWithTheAllowlistOff() public {
        address v = factory.activateVault(false, _noCalls());
        assertFalse(IAllowlistView(v).allowlistEnabled(), "allowlist should be off");
        assertTrue(IAllowlistView(v).isAssetAllowed(address(usdc)), "guard-registered asset must pass");
    }

    /// ...and ON restricts to what the vault itself has listed.
    function test_activatingWithTheAllowlistOn() public {
        address v = factory.activateVault(true, _noCalls());
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
        guard.setLatestImpl(IMPLEMENTATION_VAULT, address(newImpl)); // governance points at a new build

        assertEq(factory.vaultAddress(owner), predictedBefore, "vault address moved with the implementation");

        // ...and the vault actually deployed there runs the NEW build.
        vm.prank(owner);
        address deployed = factory.activateVault(true, _noCalls());
        assertEq(deployed, predictedBefore, "deployed somewhere other than predicted");
        assertEq(_implOf(deployed), address(newImpl), "not upgraded off the bootstrap");
    }

    /// A vault leaves the bootstrap in the same transaction it is created in.
    function test_vaultDoesNotStayOnTheBootstrap() public {
        vm.prank(owner);
        address v = factory.activateVault(true, _noCalls());
        assertEq(_implOf(v), address(impl), "should be on the real implementation");
        assertTrue(_implOf(v) != BITTY_VAULT_BOOTSTRAP, "still on the bootstrap");
    }

    /**
     * The factory is itself a proxy born on BittyV1VaultFactoryBootstrap. Only the guard's owner may
     * upgrade it off the bootstrap, and once upgraded it mints vaults normally — so factory logic can
     * change at a fixed address without moving vault addresses.
     */
    function test_onlyTheOwnerMayUpgradeOffTheFactoryBootstrap() public {
        address factoryOwner = makeAddr("factoryOwner");
        guard.setConfigAddress(CFG_OWNER, factoryOwner);

        address proxy = address(new ERC1967Proxy(address(new BittyV1VaultFactoryBootstrap()), ""));
        address build = address(new BittyV1VaultFactory());

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FactoryBootstrapNotOwner.selector);
        UUPSUpgradeable(proxy).upgradeToAndCall(build, "");

        vm.prank(factoryOwner);
        UUPSUpgradeable(proxy).upgradeToAndCall(build, "");

        vm.prank(owner);
        address v = BittyV1VaultFactory(proxy).activateVault(true, _noCalls());
        assertEq(BittyV1Vault(payable(v)).owner(), owner, "the proxied factory mints a working vault");
    }

    /**
     * Once the proxy is on a factory BUILD (not the bootstrap), a further upgrade runs the factory's
     * OWN _authorizeUpgrade — gated on owner() = the guard's configured owner — rather than the
     * bootstrap's gate. Covers owner(), the onlyOwner modifier (both branches), and _authorizeUpgrade.
     */
    function test_ownerMayUpgradeTheFactoryLogicItself() public {
        address factoryOwner = makeAddr("factoryOwner");
        guard.setConfigAddress(CFG_OWNER, factoryOwner);

        address proxy = address(new ERC1967Proxy(address(new BittyV1VaultFactoryBootstrap()), ""));
        address firstBuild = address(new BittyV1VaultFactory());
        vm.prank(factoryOwner);
        UUPSUpgradeable(proxy).upgradeToAndCall(firstBuild, "");

        assertEq(BittyV1VaultFactory(proxy).owner(), factoryOwner, "owner() reflects the guard's configured owner");

        // The proxy now runs a factory build, so this upgrade goes through the factory's own onlyOwner.
        address newBuild = address(new BittyV1VaultFactory());

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BittyV1VaultFactory.NotOwner.selector);
        UUPSUpgradeable(proxy).upgradeToAndCall(newBuild, "");

        vm.prank(factoryOwner);
        UUPSUpgradeable(proxy).upgradeToAndCall(newBuild, "");
        assertEq(_implOf(proxy), newBuild, "the owner upgraded the factory logic in place");
    }

    function _implOf(address proxy) internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, slot))));
    }
}
