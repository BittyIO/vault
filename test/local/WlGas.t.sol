// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

abstract contract Base is Test {
    BittyV1Vault vault;
    MockERC20 usdc;
    address owner = makeAddr("owner");
    address cold = makeAddr("cold");
    address gw = makeAddr("gw");
    uint256 constant UNCHANGED = type(uint256).max;
    uint256 id;

    function _build() internal {
        _build(7 days);
    }

    function _build(uint64 window) internal {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        BittyV1VaultDeFiFacet f = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(f));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BittyV1Vault.initialize, (owner, gw, false, address(0), 0, new bytes[](0)))
                ))
        );
        usdc = new MockERC20("USD Coin", "USDC", 6);
        MockGuard(BITTY_GUARD).setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 1_000_000e6);
        if (window != 0) {
            vm.prank(owner);
            vault.updateRisk(IBittyV1Owner.RiskSettings(window, UNCHANGED));
        }
        vm.prank(owner);
        id = vault.addWhitelistedRecipient(cold, address(0));
        vm.warp(block.timestamp + 8 days);
        _send(); // warm the ERC20 balances in setUp's own transaction
    }

    function _send() internal returns (uint256 used) {
        vm.prank(owner);
        uint256 g = gasleft();
        vault.sendToWhitelistedRecipient(id, address(usdc), 1e6, new address[](0), new uint256[](0));
        used = g - gasleft();
    }
}

/// Never locked: the entry's epoch stamp equals lockEpoch, so clause one hits.
contract WlGasCurrentTest is Base {
    function setUp() public {
        _build();
    }

    function test_oneSend() public {
        console2.log("epoch CURRENT  (clause 1)", _send());
    }
}

/// Locked once and released: the stamp is behind, so the first send must read closedAt[0].
contract WlGasStaleTest is Base {
    function setUp() public {
        _build();
        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vault.unlock();
    }

    function test_oneSend() public {
        console2.log("epoch STALE    (derive+settle)", _send());
    }
}

/// The same vault, after one send has recorded the verdict. Every payout from here is this price.
contract WlGasSettledTest is Base {
    function setUp() public {
        _build();
        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vault.unlock();
        _send(); // derives the verdict once and stamps SETTLED
    }

    function test_oneSend() public {
        console2.log("epoch SETTLED  (sentinel)", _send());
    }
}

/// A vault with no protection window: settled at birth by rule B.
contract WlGasNoWindowTest is Base {
    function setUp() public {
        _build(0); // no protection window at all, so the entry is SETTLED at birth
        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vault.unlock();
    }

    function test_oneSend() public {
        console2.log("no window, locked once   ", _send());
    }
}
