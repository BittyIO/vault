// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {BITTY_GUARD, PERM_YIELD, PERM_SUPPLY} from "../../src/logic/Constants.sol";

/**
 * WHAT A SLOT COSTS, PER CALL.
 *
 * A printing harness, not a set of assertions: it exists so a packing change can be justified with
 * measured numbers instead of slot arithmetic done on paper. Run it before and after.
 *
 * Each measurement gets its OWN test contract and makes exactly ONE measured call, because Foundry
 * shares the warm-storage access list across a whole test body — a second call in the same body
 * reads every slot the first one touched at warm prices and hides exactly what is being measured.
 * Fixtures are built in `setUp`, which is its own transaction.
 */
abstract contract Base is Test {
    BittyV1Vault vault;
    BittyV1VaultDeFiFacet facet;
    MockERC20 usdc;
    MockLendingProtocol sky;
    address owner = makeAddr("owner");
    address manager = makeAddr("manager");
    address cold = makeAddr("cold");
    address gw = makeAddr("gw");
    uint256 constant UNCHANGED = type(uint256).max;
    uint256 id;

    function _build() internal {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BittyV1Vault.initialize, (owner, gw, false, address(0), 0, new bytes[](0)))
                ))
        );
        usdc = new MockERC20("USD Coin", "USDC", 6);
        sky = new MockLendingProtocol();
        MockGuard(BITTY_GUARD).setAsset(address(usdc), ASSET_STABLE_COIN);
        MockGuard(BITTY_GUARD).setProtocol(address(sky), LENDING_ID);
        usdc.mint(address(vault), 1_000_000e6);

        vm.prank(owner);
        id = vault.addWhitelistedRecipient(cold, address(0));
        // Warm every fixture's PERSISTENT state in setUp's own transaction, so the measured call pays
        // cold reads only on the slots under test and not on first-touch SSTOREs elsewhere.
        _deposit(owner);
        vm.prank(owner);
        vault.sendToWhitelistedRecipient(id, address(usdc), 1e6, new address[](0), new uint256[](0));
    }

    function _f() internal view returns (BittyV1VaultDeFiFacet) {
        return BittyV1VaultDeFiFacet(payable(address(vault)));
    }

    function _deposit(address who) internal returns (uint256 used) {
        vm.prank(who);
        uint256 g = gasleft();
        _f().deposit(address(sky), address(usdc), 1e6);
        used = g - gasleft();
    }
}

/**
 *  The authority lookup on its own: `owner()` and nothing else.
 */
contract SlotGasOwnerReadTest is Base {
    function setUp() public {
        _build();
    }

    function test_ownerRead() public {
        uint256 g = gasleft();
        vault.owner();
        console2.log("owner() cold", g - gasleft());
    }
}

/**
 *  The live-grant lookup on its own.
 */
contract SlotGasGrantReadTest is Base {
    function setUp() public {
        _build();
    }

    function test_grantRead() public {
        uint256 g = gasleft();
        _f().getAssetManagerSettings();
        console2.log("getAssetManagerSettings() cold", g - gasleft());
    }
}

/**
 *  A real owner-gated write on the main vault.
 */
contract SlotGasOwnerWriteTest is Base {
    function setUp() public {
        _build();
    }

    function test_ownerWrite() public {
        vm.prank(owner);
        uint256 g = gasleft();
        vault.addWhitelistedRecipient(makeAddr("payee"), address(0));
        console2.log("addWhitelistedRecipient", g - gasleft());
    }
}

/**
 *  The hot path: a payout to a settled whitelisted recipient.
 */
contract SlotGasSendTest is Base {
    function setUp() public {
        _build();
    }

    function test_send() public {
        vm.prank(owner);
        uint256 g = gasleft();
        vault.sendToWhitelistedRecipient(id, address(usdc), 1e6, new address[](0), new uint256[](0));
        console2.log("sendToWhitelistedRecipient", g - gasleft());
    }
}

/**
 *  A real DeFi call made by the OWNER, who pays the manager check before falling back.
 */
contract SlotGasDepositByOwnerTest is Base {
    function setUp() public {
        _build();
    }

    function test_depositByOwner() public {
        console2.log("deposit (owner)", _deposit(owner));
    }
}

/**
 *  The same call made by a live manager, so the grant decides it.
 */
contract SlotGasDepositByManagerTest is Base {
    function setUp() public {
        _build();
        vm.prank(owner);
        _f().setAssetManager(manager, 0, PERM_YIELD | PERM_SUPPLY);
    }

    function test_depositByManager() public {
        console2.log("deposit (manager)", _deposit(manager));
    }
}

/**
 * THE PACKING ITSELF, ASSERTED.
 *
 * The measurements above are only true for as long as these fields keep sharing a word, and nothing
 * in {BittyStorage} makes that visible — a field inserted in the middle of either struct repacks the
 * slot, every number above quietly goes back up by about 2,000, and no test fails. These two do.
 *
 * Neither pins a slot INDEX, because the index is allowed to move: each sets every field in the
 * group to a distinct non-zero value and then looks for one storage word that the whole group
 * decodes out of, at the bit offsets Solidity would have used. Finding none is the failure.
 */
contract SlotPackingTest is Base {
    bytes32 constant VAULT_SLOT = 0x17e3e73c9899a2a21e7ae5b2fc286a77d4903c0979f27baf0730ce5db138e400;
    bytes32 constant DEFI_SLOT = 0xfcb7e45a818f0ecef03db92f5b6e7b2ed559effd8e9a1c8a33ce82a8fa3b9400;
    uint256 constant SCAN = 24;

    function setUp() public {
        _build();
    }

    function _word(bytes32 root, uint256 i) internal view returns (uint256) {
        return uint256(vm.load(address(vault), bytes32(uint256(root) + i)));
    }

    /**
     * `lockLevel` + `lockEpoch` + `ownershipReadyAt` + `vaultOwner`, in one word — what makes
     * {BittyV1AccountBase-owner} a single cold read on every authorised call in the vault.
     *
     * In TWO PHASES, because the four can no longer all be non-zero at once: a lock voids a
     * handover that is still waiting, so `lockLevel` and `ownershipReadyAt` are now mutually
     * exclusive by construction. Phase one finds the word holding the clock and the owner; phase
     * two locks and requires the lock level and the epoch to appear in THAT SAME word. Together
     * they pin all four to one slot, and the exclusivity is asserted on the way through.
     */
    function test_theAuthoritySlotHoldsAllFourFields() public {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(2 days, UNCHANGED));
        vm.prank(owner);
        vault.transferOwnership(makeAddr("successor"));
        uint40 readyAt = uint40(block.timestamp + 2 days);

        uint256 found = type(uint256).max;
        for (uint256 i; i < SCAN; ++i) {
            uint256 w = _word(VAULT_SLOT, i);
            if (uint40(w >> 40) != readyAt) continue; // ownershipReadyAt
            if (address(uint160(w >> 80)) != owner) continue; // vaultOwner
            found = i;
            break;
        }
        assertTrue(found != type(uint256).max, "the handover clock and the owner are not one word");

        vm.prank(owner);
        vault.emergencyLock();

        uint256 word = _word(VAULT_SLOT, found);
        assertEq(uint8(word), 1, "lockLevel is not in that word");
        assertEq(uint32(word >> 8), 1, "lockEpoch is not in that word");
        assertEq(uint40(word >> 40), 0, "the lock did not void the waiting handover");
        assertEq(address(uint160(word >> 80)), owner, "vaultOwner moved out of that word");
        assertEq(vault.owner(), owner, "and the handover is gone, so the vault is still the owner's");
    }

    /**
     * `assetManager` + `assetManagerExpiresAt` + `assetManagerPerms` + `hasPendingAssetManager`, in
     * one word — what makes the grant check a single cold read on every DeFi call.
     */
    function test_theGrantSlotHoldsAllFourFields() public {
        uint64 expiry = uint64(block.timestamp + 30 days);
        vm.prank(owner);
        _f().setAssetManager(manager, expiry, PERM_YIELD);
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(2 days, UNCHANGED));
        // Widening the grant is a loosening, so it queues — which is what sets the pending flag.
        vm.prank(owner);
        _f().setAssetManager(manager, expiry, PERM_YIELD | PERM_SUPPLY);

        (,,,, uint32 permissions,) = _f().getAssetManagerSettings();
        assertEq(permissions, PERM_YIELD, "the wider grant is still waiting");

        for (uint256 i; i < SCAN; ++i) {
            uint256 w = _word(DEFI_SLOT, i);
            if (address(uint160(w)) != manager) continue;
            if (uint48(w >> 160) != expiry) continue; // assetManagerExpiresAt
            if (uint32(w >> 208) != PERM_YIELD) continue; // assetManagerPerms
            if (uint8(w >> 240) != 1) continue; // hasPendingAssetManager
            return;
        }
        fail();
    }
}

/**
 * THE SLOT WE STOPPED USING.
 *
 * Keeping the owner in {VaultStorage.vaultOwner} leaves {OwnableUpgradeable}'s own slot at zero
 * forever, which is safe only because the library reads it in exactly two places and
 * {BittyV1AccountBase} overrides both. That is a fact about a dependency, so it is asserted rather
 * than trusted: if an OpenZeppelin bump starts writing that slot — or starts reading it somewhere
 * the override does not cover — this fails, and whoever did the bump finds out here instead of in a
 * vault whose authority check reads a zero.
 */
contract AbandonedOwnableSlotTest is Base {
    bytes32 constant OZ_OWNABLE_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    function setUp() public {
        _build();
    }

    function test_openZeppelinsOwnerSlotIsNeverWritten() public {
        assertEq(vm.load(address(vault), OZ_OWNABLE_SLOT), bytes32(0), "initialize wrote OZ's slot");
        assertEq(vault.owner(), owner, "and ours is the one that answers");

        address successor = makeAddr("successor");
        vm.prank(owner);
        vault.transferOwnership(successor); // no timelock set, so this hands over in the call

        assertEq(vm.load(address(vault), OZ_OWNABLE_SLOT), bytes32(0), "the handover wrote OZ's slot");
        assertEq(vault.owner(), successor);
    }
}

/**
 *  `owner()` while a handover has matured but nobody has written it down yet.
 */
contract SlotGasMaturedHandoverTest is Base {
    function setUp() public {
        _build();
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(2 days, UNCHANGED));
        vm.prank(owner);
        vault.transferOwnership(makeAddr("successor"));
        vm.warp(block.timestamp + 2 days);
    }

    function test_ownerReadWhileMatured() public {
        uint256 g = gasleft();
        address who = vault.owner();
        console2.log("owner() cold, handover matured+unsettled", g - gasleft());
        assertEq(who, makeAddr("successor"));
    }
}

/**
 *  What voiding a waiting handover adds to the lock.
 */
contract SlotGasLockNothingPendingTest is Base {
    function setUp() public {
        _build();
    }

    function test_lockWithNothingPending() public {
        vm.prank(owner);
        uint256 g = gasleft();
        vault.emergencyLock();
        console2.log("emergencyLock, nothing pending", g - gasleft());
    }
}

contract SlotGasLockHandoverPendingTest is Base {
    function setUp() public {
        _build();
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(2 days, UNCHANGED));
        vm.prank(owner);
        vault.transferOwnership(makeAddr("thief"));
    }

    function test_lockWithAHandoverToVoid() public {
        vm.prank(owner);
        uint256 g = gasleft();
        vault.emergencyLock();
        console2.log("emergencyLock, handover to void", g - gasleft());
    }
}
