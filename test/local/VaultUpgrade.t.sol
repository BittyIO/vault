// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {ImplementationNotRegistered} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * @notice A V2 of the main vault, as a real upgrade would ship it: same base, plus brand-new state in its
 *         OWN ERC-7201 namespace so it cannot collide with any V1 slot. Proves the pattern that keeps
 *         upgrades storage-safe — new fields go in a fresh namespaced struct, never appended to V1's.
 * @dev Slot = keccak256(abi.encode(uint256(keccak256("bitty.v2.vault.main")) - 1)) & ~0xff.
 */
interface IVaultVersion {
    function vaultVersion() external view returns (uint256);
    function versionName() external view returns (string memory);
}

contract BittyV2Vault is BittyV1Vault {
    bytes32 private constant V2_SLOT = 0x7ecb699a06ee21ad3b6687b1a055b97ffa71638bb69215fc9703e69f6463c300;

    struct V2Storage {
        uint256 counter;
        string label;
    }

    function _v2() private pure returns (V2Storage storage $) {
        assembly {
            $.slot := V2_SLOT
        }
    }

    constructor(address defiFacet, address subVaultImpl) BittyV1Vault(defiFacet, subVaultImpl) {}

    /// One-time V2 migration, runnable exactly once via {reinitializer}; call it atomically in upgradeToAndCall.
    function initializeV2(string memory label_) external reinitializer(2) {
        _v2().label = label_;
    }

    function setCounter(uint256 v) external onlyOwner {
        _v2().counter = v;
    }

    function counter() external view returns (uint256) {
        return _v2().counter;
    }

    function label() external view returns (string memory) {
        return _v2().label;
    }

    function version() external pure returns (string memory) {
        return "V2";
    }
}

/**
 * The owner-driven, guard-gated UUPS upgrade path (BittyV1VaultBase.upgrade / _authorizeUpgrade):
 * a vault upgrades to a guard-registered BittyV2Vault, keeps all V1 state, and gains V2 storage that
 * lives in its own namespace. Also covers the two rejections: unregistered impl, and non-owner caller.
 */
contract VaultUpgradeTest is Test {
    MockGuard guard;
    BittyV1VaultDeFiFacet facet;
    BittyV1SubVault subImpl;
    BittyV1Vault vaultImpl;
    BittyV1Vault vault;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address subOwner = makeAddr("subOwner");
    address weth = makeAddr("weth");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        facet = new BittyV1VaultDeFiFacet();
        subImpl = new BittyV1SubVault(address(facet));
        vaultImpl = new BittyV1Vault(address(facet), address(subImpl));

        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(vaultImpl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(address(vault), 1_000e6);
    }

    function _deployV2() internal returns (BittyV2Vault v2Impl) {
        v2Impl = new BittyV2Vault(address(facet), address(subImpl));
    }

    function test_upgradeToV2PreservesStateAndAddsStorage() public {
        // Build up some V1 state first: an open sub vault, plus the vault's token balance.
        vm.prank(owner);
        vault.createSubVault(subOwner, false, uint64(block.timestamp) + 365 days);
        assertEq(vault.subVaultOpenCount(), 1, "pre: one sub open");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "pre: balance");

        BittyV2Vault v2Impl = _deployV2();
        guard.setImpl(address(v2Impl), true);

        // Upgrade AND run the V2 migration atomically, exactly as production would.
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), abi.encodeCall(BittyV2Vault.initializeV2, ("bitty-v2")));

        BittyV2Vault v2 = BittyV2Vault(payable(address(vault)));

        // New behaviour is live.
        assertEq(v2.version(), "V2", "new function");
        assertEq(v2.label(), "bitty-v2", "V2 migration ran");

        // New storage works and is owner-gated (ownership survived the upgrade).
        vm.prank(owner);
        v2.setCounter(42);
        assertEq(v2.counter(), 42, "V2 storage write");

        // All V1 state is intact — nothing was overwritten by the new namespace.
        assertEq(vault.owner(), owner, "owner preserved");
        assertEq(vault.subVaultOpenCount(), 1, "sub count preserved");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "balance preserved");
    }

    function test_upgradeViaUpgradeHelperThenMigrateSeparately() public {
        BittyV2Vault v2Impl = _deployV2();
        guard.setImpl(address(v2Impl), true);

        // The bare upgrade() helper passes empty data; the migration is a separate call.
        vm.prank(owner);
        vault.upgrade(address(v2Impl));

        BittyV2Vault v2 = BittyV2Vault(payable(address(vault)));
        assertEq(v2.label(), "", "not migrated yet");

        vm.prank(owner);
        v2.initializeV2("later");
        assertEq(v2.label(), "later", "migrated after");
    }

    function test_migrationCannotRunTwice() public {
        BittyV2Vault v2Impl = _deployV2();
        guard.setImpl(address(v2Impl), true);
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), abi.encodeCall(BittyV2Vault.initializeV2, ("once")));

        BittyV2Vault v2 = BittyV2Vault(payable(address(vault)));
        vm.prank(owner);
        vm.expectRevert(); // Initializable: already at version 2
        v2.initializeV2("again");
    }

    function test_upgradeRejectsUnregisteredImpl() public {
        BittyV2Vault v2Impl = _deployV2();
        // Deliberately NOT registered in the guard.
        vm.prank(owner);
        vm.expectRevert(ImplementationNotRegistered.selector);
        vault.upgrade(address(v2Impl));
    }

    function test_upgradeRejectsNonOwner() public {
        BittyV2Vault v2Impl = _deployV2();
        guard.setImpl(address(v2Impl), true); // registered, so the only thing left to reject is the caller
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        vault.upgrade(address(v2Impl));
    }

    /// The vault names its own release the same way an adapter does, so one ABI reads either.
    function test_vaultReportsItsVersion() public {
        assertEq(IVaultVersion(address(vault)).vaultVersion(), 1_000_000, "encoded 1.0.0");
        assertEq(IVaultVersion(address(vault)).versionName(), "1.0.0", "readable form");
    }
}
