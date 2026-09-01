// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {SubOwnerDeadlineRequired} from "../../src/interfaces/IBittyV1SubVault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {IBittyV1SubVault} from "../../src/interfaces/IBittyV1SubVault.sol";
import {NoRescueTarget, OwnershipNotRenounceable} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * The sub-vault lifecycle through the registry: create (guard-gated impl) → fund (main → sub) → recall
 * (sub → main) → close, with openSubCount tracking and renounce blocked while any sub is open.
 */
contract SubVaultLifecycleTest is Test {
    BittyV1VaultDeFiFacet facet;
    BittyV1Vault vaultImpl;
    BittyV1SubVault subImpl;
    BittyV1Vault vault;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address subOwner = makeAddr("subOwner");
    address weth = makeAddr("weth");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);

        facet = new BittyV1VaultDeFiFacet();
        subImpl = new BittyV1SubVault(address(facet));
        vaultImpl = new BittyV1Vault(address(facet), address(subImpl));

        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(vaultImpl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(address(vault), 1_000e6);
    }

    function test_createFundRecallClose() public {
        // create
        vm.prank(owner);
        (uint256 subId, address account) = vault.createSubVault(subOwner, false, uint64(block.timestamp) + 365 days);
        assertEq(vault.subVaultOpenCount(), 1, "one sub open");
        assertEq(BittyV1SubVault(payable(account)).vault(), address(vault), "parent link");
        assertEq(BittyV1SubVault(payable(account)).owner(), subOwner, "sub owner");

        // fund main -> sub
        vm.prank(owner);
        vault.fundSubVault(subId, _one(address(usdc)), _one(600e6));
        assertEq(usdc.balanceOf(account), 600e6, "sub funded");
        assertEq(usdc.balanceOf(address(vault)), 400e6, "main debited");

        // recall sub -> main
        vm.prank(owner);
        vault.recallFromSubVault(subId, _one(address(usdc)), _one(250e6));
        assertEq(usdc.balanceOf(account), 350e6, "sub after recall");
        assertEq(usdc.balanceOf(address(vault)), 650e6, "main credited");

        // close
        vm.prank(owner);
        vault.closeSubVault(subId);
        assertEq(vault.subVaultOpenCount(), 0, "no subs open");
    }

    function test_createSubVaultWithDeposits() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        usdc.mint(address(vault), 1_000e6);
        dai.mint(address(vault), 500e18);

        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        assets[0] = address(usdc);
        amounts[0] = 600e6;
        assets[1] = address(dai);
        amounts[1] = 200e18;

        vm.prank(owner);
        (, address account) =
            vault.createSubVaultWithDeposits(subOwner, false, uint64(block.timestamp) + 365 days, assets, amounts);

        assertEq(vault.subVaultOpenCount(), 1, "sub created");
        assertEq(usdc.balanceOf(account), 600e6, "USDC deposited");
        assertEq(dai.balanceOf(account), 200e18, "DAI deposited");
        assertEq(usdc.balanceOf(address(vault)), 1_400e6, "main debited USDC");
        assertEq(dai.balanceOf(address(vault)), 300e18, "main debited DAI");
    }

    /**
     * An open sub does not block renounce, because a sub can no longer exist without a deadline. Every
     * grant terminates on its own, and once lapsed both the unwind and the return to the parent are
     * permissionless — so the vault drains with nobody left holding a key.
     */
    function test_anOpenSubDoesNotBlockRenounce() public {
        vm.prank(owner);
        vault.createSubVault(subOwner, false, uint64(block.timestamp) + 365 days);

        vm.prank(owner);
        vm.expectRevert(NoRescueTarget.selector); // the rescue target is all that is left to satisfy
        vault.renounceVaultOwnership(0);
    }

    /// A grant with no deadline cannot be created in the first place.
    function test_aSubWithoutADeadlineIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(SubOwnerDeadlineRequired.selector);
        vault.createSubVault(subOwner, false, 0);
    }

    function test_directRenounceOwnershipBlocked() public {
        // The inherited renounceOwnership() must be shut — renounce can only go through the guarded
        // renounceVaultOwnership, so a single call can't zero the owner and strand the funds.
        vm.prank(owner);
        vm.expectRevert(OwnershipNotRenounceable.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), owner, "ownership intact");
    }

    function test_onlyOwnerCanManageSubs() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        vault.createSubVault(subOwner, false, uint64(block.timestamp) + 365 days);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _one(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }
}
