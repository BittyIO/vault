// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN, ASSET_AMM_LIQUID} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockMarketProtocol} from "../helpers/MockMarketProtocol.sol";
import {MARKET_TRADE_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 *  What holding a route to the allow list costs, now that the adapter does the parsing.
 */
abstract contract Base is Test {
    BittyV1Vault vault;
    MockMarketProtocol trade;
    MockERC20 usdc;
    MockERC20 mid;
    MockERC20 dai;
    address owner = makeAddr("owner");

    function _build() internal {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        BittyV1VaultDeFiFacet f = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(f));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        BittyV1Vault.initialize, (owner, makeAddr("gw"), false, address(0), 0, new bytes[](0))
                    )
                ))
        );
        usdc = new MockERC20("USDC", "USDC", 6);
        mid = new MockERC20("MID", "MID", 18);
        dai = new MockERC20("DAI", "DAI", 18);
        trade = new MockMarketProtocol();
        MockGuard(BITTY_GUARD).setAsset(address(usdc), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        MockGuard(BITTY_GUARD).setAsset(address(mid), ASSET_AMM_LIQUID);
        MockGuard(BITTY_GUARD).setAsset(address(dai), ASSET_STABLE_COIN | ASSET_AMM_LIQUID);
        MockGuard(BITTY_GUARD).setProtocol(address(trade), MARKET_TRADE_ID);
        usdc.mint(address(vault), 1_000_000e6);
        _sell(_path2()); // clone, approvals and every fixture warmed in setUp's own transaction
    }

    function _f() internal view returns (BittyV1VaultDeFiFacet) {
        return BittyV1VaultDeFiFacet(payable(address(vault)));
    }

    function _path2() internal view returns (bytes memory) {
        return abi.encodePacked(address(usdc), uint24(500), address(dai));
    }

    function _path3() internal view returns (bytes memory) {
        return abi.encodePacked(address(usdc), uint24(500), address(mid), uint24(500), address(dai));
    }

    function _sell(bytes memory path) internal returns (uint256 used) {
        vm.prank(owner);
        uint256 g = gasleft();
        _f().marketSell(address(trade), address(usdc), 1e6, address(dai), 0, path);
        used = g - gasleft();
    }
}

contract RouteGasOneHopTest is Base {
    function setUp() public {
        _build();
    }

    function test_oneHop() public {
        console2.log("marketSell, 1 hop (2 assets)", _sell(_path2()));
    }
}

contract RouteGasTwoHopTest is Base {
    function setUp() public {
        _build();
    }

    function test_twoHop() public {
        console2.log("marketSell, 2 hops (4 assets)", _sell(_path3()));
    }
}
