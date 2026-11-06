// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {PriceFeed} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockFeed} from "./MarketTradeGuard.t.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {Create2Address} from "../../src/logic/Create2Address.sol";
import {PriceLib} from "../../src/logic/PriceLib.sol";
import {
    BITTY_GUARD,
    BITTY_VAULT_BOOTSTRAP,
    TRON_MAINNET_CHAIN_ID,
    TRON_NILE_CHAIN_ID
} from "../../src/logic/Constants.sol";

contract PriceLibHarness {
    function nativeUsdValue(uint256 amount, PriceFeed memory feed) external view returns (uint256) {
        return PriceLib.usdValue(address(0), 0, amount, Math.Rounding.Floor, feed, feed);
    }
}

/**
 * What differs between the TVM and the EVM this suite runs on, and that the contracts must get right.
 */
contract TronSemanticsTest is Test {
    BittyV1VaultFactory factory;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        factory = BittyV1VaultFactory(address(new ERC1967Proxy(address(new BittyV1VaultFactory()), "")));
    }

    function _proxyInitCodeHash() internal pure returns (bytes32) {
        return
            keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(BITTY_VAULT_BOOTSTRAP, bytes(""))));
    }

    function _expected(bytes1 prefix, address owner) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(owner));
        return
            address(uint160(uint256(keccak256(abi.encodePacked(prefix, address(factory), salt, _proxyInitCodeHash())))));
    }

    /**
     * The TVM's CREATE2 hashes with 0x41, so a vault address predicted with the EVM's 0xff on TRON
     * would be one users fund and the vault never lands at.
     */
    function test_onTronTheVaultAddressUsesThe0x41Prefix() public {
        address owner = makeAddr("owner");
        vm.chainId(TRON_MAINNET_CHAIN_ID);
        assertEq(factory.vaultAddress(owner), _expected(0x41, owner), "mainnet");
        vm.chainId(TRON_NILE_CHAIN_ID);
        assertEq(factory.vaultAddress(owner), _expected(0x41, owner), "nile");
        assertTrue(_expected(0x41, owner) != _expected(0xff, owner));
    }

    /**
     * Off TRON the prediction stays the EVM's, which is what lets the rest of this suite check it
     * against where the vault really lands.
     */
    function test_offTronTheVaultAddressUsesThe0xffPrefix() public view {
        address owner = address(0xBEEF);
        assertEq(factory.vaultAddress(owner), _expected(0xff, owner));
    }

    /**
     * Split in two because via-IR reads `block.chainid` once per call frame, so a `vm.chainId` in
     * the middle of one test function is not seen by an inlined library call after it.
     */
    function test_offTronThePrefixIs0xff() public view {
        assertEq(Create2Address.prefix(), bytes1(0xff));
    }

    function test_onTronThePrefixIs0x41() public {
        vm.chainId(TRON_MAINNET_CHAIN_ID);
        assertEq(this.prefixNow(), bytes1(0x41));
    }

    function prefixNow() external view returns (bytes1) {
        return Create2Address.prefix();
    }

    /**
     * TRX is counted in sun, 6 decimals: 1 TRX at $0.30 is $0.30, not $0.30 / 1e12.
     */
    function test_nativeTrxIsPricedAtSixDecimals() public {
        MockFeed feed = new MockFeed();
        feed.set(0.3e8, block.timestamp, block.timestamp);
        PriceFeed memory p = PriceFeed({
            feed: address(feed), maxAge: 1 hours, decimals: 8, assetDecimals: 0, hasQuote: false, quote: address(0)
        });
        assertEq(new PriceLibHarness().nativeUsdValue(1e6, p), 0.3e18);
    }
}
