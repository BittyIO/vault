// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN, ASSET_CRYPTO} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {AutoYield, IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, PERM_YIELD} from "../../src/logic/Constants.sol";

/**
 * What the lock gate costs, function by function.
 *
 * Not an assertion suite — it prints gas so the same run can be compared against a build with the
 * gate removed. The difference is the whole price of the feature on an unlocked vault, which is what
 * every ordinary call pays.
 *
 * The gate is one SLOAD of `lockLevel`, so the only question per function is whether that slot was
 * going to be read anyway. It shares a slot with `lockEpoch` — the two pack together — so any
 * function that stamps an epoch warms it either way and pays almost nothing for the check.
 */
contract LockGasCostTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockERC20 weth;
    MockLendingProtocol sky;

    address owner = makeAddr("owner");
    address heir = makeAddr("heir");
    address payee = makeAddr("payee");
    address gasWrapped = makeAddr("gasWrapped");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)))
                ))
        );
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        sky = new MockLendingProtocol();
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setAsset(address(weth), ASSET_CRYPTO);
        guard.setProtocol(address(sky), LENDING_ID);
        usdc.mint(address(vault), 100_000e6);

        // Every fixture call is made HERE rather than inside a test. setUp is a separate
        // transaction, so none of it leaves `lockLevel` warm for the measurement that follows —
        // which an owner-gated call in the test body would, making the gate look free.
        vm.startPrank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(1 days, UNCHANGED));
        _f().updateProtocols(_one(address(sky)), _none());
        _f().updateAssets(_one(address(usdc)), _none());
        _f().setAutoYielding(AutoYield({asset: address(usdc), protocol: address(sky)}));
        vm.stopPrank();
    }

    function _f() internal view returns (BittyV1VaultDeFiFacet) {
        return BittyV1VaultDeFiFacet(payable(address(vault)));
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _noAmounts() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function _measure(string memory name, bytes memory call) internal {
        vm.prank(owner);
        uint256 before = gasleft();
        (bool ok,) = address(vault).call(call);
        uint256 used = before - gasleft();
        require(ok, name);
        console2.log(name, used);
    }

    /**
     * One function per test, deliberately.
     *
     * Warm-storage accounting is per transaction, and a Foundry test body is one transaction — so
     * measuring several calls in a row would charge only the first for the cold read of `lockLevel`
     * and let every later one find it warm. Each measurement below is the first storage touch of its
     * own transaction, which is what a call from a real wallet is.
     */
    function test_gas_addWhitelistedRecipient() public {
        _measure("addWhitelistedRecipient", abi.encodeCall(BittyV1Vault.addWhitelistedRecipient, (payee, address(0))));
    }

    function test_gas_transferOwnership() public {
        _measure("transferOwnership", abi.encodeCall(BittyV1Vault.transferOwnership, (heir)));
    }

    function test_gas_updateRisk() public {
        _measure("updateRisk", abi.encodeCall(BittyV1Vault.updateRisk, (IBittyV1Owner.RiskSettings(1 days, UNCHANGED))));
    }

    function test_gas_send() public {
        _measure("send", abi.encodeCall(BittyV1Vault.send, (payee, address(usdc), 1e6, _none(), _noAmounts())));
    }

    function test_gas_setStableCoinAsGas() public {
        _measure("setStableCoinAsGas", abi.encodeCall(BittyV1Vault.setStableCoinAsGas, (_one(address(usdc)), 100, 10)));
    }

    function test_gas_disableStableCoinAsGas() public {
        _measure("disableStableCoinAsGas", abi.encodeCall(BittyV1Vault.disableStableCoinAsGas, ()));
    }

    function test_gas_updateAssets() public {
        _measure("updateAssets", abi.encodeCall(BittyV1VaultDeFiFacet.updateAssets, (_one(address(weth)), _none())));
    }

    function test_gas_updateProtocols() public {
        _measure(
            "updateProtocols", abi.encodeCall(BittyV1VaultDeFiFacet.updateProtocols, (_one(address(sky)), _none()))
        );
    }

    function test_gas_setAssetManager() public {
        _measure(
            "setAssetManager", abi.encodeCall(BittyV1VaultDeFiFacet.setAssetManager, (makeAddr("mgr"), 0, PERM_YIELD))
        );
    }

    function test_gas_setAutoYieldTrigger() public {
        _measure("setAutoYieldTrigger", abi.encodeCall(BittyV1VaultDeFiFacet.setAutoYieldTrigger, (makeAddr("keeper"))));
    }

    function test_gas_useBittyAllowList() public {
        _measure("useBittyAllowList", abi.encodeCall(BittyV1VaultDeFiFacet.useBittyAllowList, (false)));
    }

    function test_gas_setAutoYielding() public {
        _measure(
            "setAutoYielding",
            abi.encodeCall(
                BittyV1VaultDeFiFacet.setAutoYielding, (AutoYield({asset: address(usdc), protocol: address(sky)}))
            )
        );
    }

    function test_gas_deposit() public {
        _measure("deposit", abi.encodeCall(BittyV1VaultDeFiFacet.deposit, (address(sky), address(usdc), 1_000e6)));
    }

    /**
     * The question the sweep exists to answer: can a thief queue so much that engaging the lock runs
     * out of gas, leaving the owner unable to lock at all?
     *
     * No — and not because the queue is kept small, but because the lock never looks at it. Engaging
     * one closes the current risk epoch and starts a new one, which is two storage writes whatever is
     * outstanding; every queued entry carries the epoch it was made in and simply stops being
     * honoured. There is no loop in the path at all.
     *
     * Measured below against an empty vault, against a full pending queue, against fifty live
     * destinations, and on a vault that has already been locked and released several times.
     */
    function test_gas_lockUnderLoad() public {
        console2.log("lock, nothing outstanding", _gasToLock());

        setUp();
        vm.startPrank(owner);
        for (uint256 i; i < 200; ++i) {
            vault.addWhitelistedRecipient(address(uint160(0xbad0000 + i)), address(0));
        }
        vm.stopPrank();
        console2.log("lock, 200 pending additions", _gasToLock());

        // Fifty live destinations, so the id space and the storage are loaded. Added with no wait,
        // which is also why none of them occupies a place in the pending queue.
        setUp();
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(0, UNCHANGED));
        vm.warp(block.timestamp + 1 days + 1); // dropping the wait is a loosening, so it waits
        vm.startPrank(owner);
        for (uint256 i; i < 50; ++i) {
            vault.addWhitelistedRecipient(address(uint160(0xf00d0000 + i)), address(0));
        }
        vm.stopPrank();
        console2.log("lock, 50 live destinations ", _gasToLock());

        // And on a vault with a history of locks, so the epoch counter and its record have grown.
        setUp();
        for (uint256 i; i < 5; ++i) {
            vm.prank(owner);
            vault.emergencyLock();
            vm.prank(owner);
            vault.unlock();
        }
        console2.log("lock, sixth time           ", _gasToLock());
    }

    function _gasToLock() private returns (uint256 used) {
        vm.prank(owner);
        uint256 before = gasleft();
        vault.emergencyLock();
        used = before - gasleft();
    }

    function test_gas_autoYield() public {
        _measure("autoYield", abi.encodeCall(BittyV1VaultDeFiFacet.autoYield, (address(usdc))));
    }
}
