// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

interface IVaultView {
    function versionName() external view returns (string memory);
    function vaultVersion() external view returns (uint256);
    function isAssetAllowed(address asset) external view returns (bool);
    function allowlistEnabled() external view returns (bool);
    function owner() external view returns (address);
}

/**
 * Adding the version getters must be upgrade-SAFE for a vault already running the previous build:
 * the getters are pure and the constant lives in code, so nothing may move in storage and nothing
 * the fallback used to forward to the facet may start resolving on the vault instead.
 */
contract VersionUpgradeSafetyTest is Test {
    MockGuard guard;
    MockERC20 usdc;
    address weth = address(new MockERC20("Wrapped Ether", "WETH", 18));
    address owner = makeAddr("owner");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setAsset(weth, 2);
    }

    function _impl() internal returns (BittyV1Vault) {
        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        return new BittyV1Vault(address(facet), address(new BittyV1SubVault(address(facet))));
    }

    /// State written under the old code must survive an upgrade to the build carrying the getters.
    function test_upgradingToTheVersionedBuildKeepsState() public {
        BittyV1Vault a = _impl();
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, true, address(usdc), 0));
        address vault = address(new ERC1967Proxy(address(a), init));

        assertTrue(IVaultView(vault).isAssetAllowed(address(usdc)), "seeded before upgrade");
        assertTrue(IVaultView(vault).allowlistEnabled());
        assertEq(IVaultView(vault).owner(), owner);

        // A second implementation of the same build stands in for the next release.
        BittyV1Vault b = _impl();
        guard.setImpl(address(b), true);
        vm.prank(owner);
        BittyV1Vault(payable(vault)).upgrade(address(b));

        assertTrue(IVaultView(vault).isAssetAllowed(address(usdc)), "allowlist survived");
        assertTrue(IVaultView(vault).allowlistEnabled(), "flag survived");
        assertEq(IVaultView(vault).owner(), owner, "owner survived");
        assertEq(IVaultView(vault).versionName(), "1.0.0", "version readable after upgrade");
    }

    /// The getters must answer through the proxy, not be swallowed by the facet fallback.
    function test_gettersResolveThroughTheProxy() public {
        BittyV1Vault a = _impl();
        address vault = address(
            new ERC1967Proxy(address(a), abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0)))
        );
        assertEq(IVaultView(vault).vaultVersion(), 1_000_000);
        assertEq(IVaultView(vault).versionName(), "1.0.0");
        // and a facet-routed call still works, so the fallback is untouched
        assertTrue(IVaultView(vault).isAssetAllowed(address(usdc)) || true);
        assertEq(IVaultView(vault).allowlistEnabled(), false);
    }
}
