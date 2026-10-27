// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {AutoYield} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * Every configuration change leaves a log, so whoever watches the vault for its owner sees a list widen
 * or a route move when it happens: the allow-list switch, the vault's own asset and protocol lists, and
 * the auto-yield routes.
 */
contract ConfigEventsTest is Test {
    BittyV1Vault vault;
    MockERC20 usdc;
    MockLendingProtocol lending;
    address owner = makeAddr("owner");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        MockGuard guard = MockGuard(BITTY_GUARD);

        BittyV1Vault impl = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        BittyV1Vault.initialize, (owner, makeAddr("gasWrapped"), false, address(0), 0, new bytes[](0))
                    )
                ))
        );

        usdc = new MockERC20("USD Coin", "USDC", 6);
        lending = new MockLendingProtocol();
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setProtocol(address(lending), LENDING_ID);
    }

    function _f() internal view returns (BittyV1VaultDeFiFacet) {
        return BittyV1VaultDeFiFacet(payable(address(vault)));
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function test_switchingTheAllowListIsLogged() public {
        vm.expectEmit(address(vault));
        emit IBittyV1Owner.OwnAllowListSet(true);
        vm.prank(owner);
        _f().useBittyAllowList(false);

        vm.expectEmit(address(vault));
        emit IBittyV1Owner.OwnAllowListSet(false);
        vm.prank(owner);
        _f().useBittyAllowList(true);
    }

    function test_updatingTheAssetListIsLogged() public {
        vm.expectEmit(address(vault));
        emit IBittyV1Owner.AssetsUpdated(_one(address(usdc)), new address[](0));
        vm.prank(owner);
        _f().updateAssets(_one(address(usdc)), new address[](0));

        vm.expectEmit(address(vault));
        emit IBittyV1Owner.AssetsUpdated(new address[](0), _one(address(usdc)));
        vm.prank(owner);
        _f().updateAssets(new address[](0), _one(address(usdc)));
    }

    function test_updatingTheProtocolListIsLogged() public {
        vm.expectEmit(address(vault));
        emit IBittyV1Owner.ProtocolsUpdated(_one(address(lending)), new address[](0));
        vm.prank(owner);
        _f().updateProtocols(_one(address(lending)), new address[](0));

        vm.expectEmit(address(vault));
        emit IBittyV1Owner.ProtocolsUpdated(new address[](0), _one(address(lending)));
        vm.prank(owner);
        _f().updateProtocols(new address[](0), _one(address(lending)));
    }

    function test_settingAndClearingAnAutoYieldRouteIsLogged() public {
        vm.expectEmit(address(vault));
        emit IBittyV1Owner.AutoYieldingSet(address(usdc), address(lending));
        vm.prank(owner);
        _f().setAutoYielding(AutoYield(address(usdc), address(lending)));

        vm.expectEmit(address(vault));
        emit IBittyV1Owner.AutoYieldingSet(address(usdc), address(0));
        vm.prank(owner);
        _f().setAutoYielding(AutoYield(address(usdc), address(0)));
    }

    function test_settingSeveralRoutesLogsEachOne() public {
        AutoYield[] memory routes = new AutoYield[](2);
        routes[0] = AutoYield(address(usdc), address(lending));
        routes[1] = AutoYield(makeAddr("other"), address(0));
        vm.expectEmit(address(vault));
        emit IBittyV1Owner.AutoYieldingSet(address(usdc), address(lending));
        vm.expectEmit(address(vault));
        emit IBittyV1Owner.AutoYieldingSet(makeAddr("other"), address(0));
        vm.prank(owner);
        _f().setAutoYieldings(routes);
    }
}
