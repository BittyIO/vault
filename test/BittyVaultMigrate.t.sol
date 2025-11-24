// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {Migrator} from "../src/Migrator.sol";

import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AddressZero} from "../src/interfaces/Errors.sol";

contract BittyVaultMigrateTest is Test {
    BittyVault public bittyVault;
    BittyVault public nextVault;
    WETH public mockWETH;
    MockERC20 public mockWBTC;
    MockERC20 public mockUSDT;
    MockERC20 public mockUSDC;
    Migrator public migrator;
    address public grantor;
    address public trustee;
    address public whiteListAddress;

    function setUp() public {
        mockWETH = new WETH();
        mockWBTC = new MockERC20("WBTC", "WBTC", 18);
        mockUSDT = new MockERC20("USDT", "USDT", 18);
        mockUSDC = new MockERC20("USDC", "USDC", 18);
        migrator = new Migrator();
        whiteListAddress = address(new WhiteList());
        grantor = makeAddr("grantor");
        trustee = makeAddr("trustee");

        // Create and initialize current vault
        bittyVault = new BittyVault();
        address[] memory assetAddresses = new address[](2);
        assetAddresses[0] = address(mockWBTC);
        assetAddresses[1] = address(mockWETH);
        address[] memory stableCoinAddresses = new address[](2);
        stableCoinAddresses[0] = address(mockUSDT);
        stableCoinAddresses[1] = address(mockUSDC);
        bittyVault.initialize(
            grantor,
            address(mockWETH),
            whiteListAddress,
            address(migrator),
            assetAddresses,
            stableCoinAddresses,
            new address[](0),
            new address[](0)
        );

        // Set trustee
        vm.prank(grantor);
        bittyVault.setTrustee(trustee);

        // Create and initialize next vault
        nextVault = new BittyVault();
        nextVault.initialize(
            grantor,
            address(mockWETH),
            whiteListAddress,
            address(migrator),
            assetAddresses,
            stableCoinAddresses,
            new address[](0),
            new address[](0)
        );

        // Set next vault in migrator
        migrator.setNextVault(address(bittyVault), address(nextVault));
    }

    function test_MigrateSuccess() public {
        // Give current vault some assets
        uint256 wbtcAmount = 1 ether;
        uint256 wethAmount = 2 ether;
        uint256 usdtAmount = 1000 * 1e18;
        uint256 usdcAmount = 2000 * 1e18;
        uint256 ethAmount = 0.5 ether;

        deal(address(mockWBTC), address(bittyVault), wbtcAmount);
        deal(address(mockWETH), address(bittyVault), wethAmount);
        deal(address(mockUSDT), address(bittyVault), usdtAmount);
        deal(address(mockUSDC), address(bittyVault), usdcAmount);
        deal(address(bittyVault), ethAmount);

        // Record balances before migration
        uint256 nextVaultWbtcBefore = mockWBTC.balanceOf(address(nextVault));
        uint256 nextVaultWethBefore = mockWETH.balanceOf(address(nextVault));
        uint256 nextVaultUsdtBefore = mockUSDT.balanceOf(address(nextVault));
        uint256 nextVaultUsdcBefore = mockUSDC.balanceOf(address(nextVault));
        uint256 nextVaultEthBefore = address(nextVault).balance;

        // Execute migration
        vm.prank(trustee);
        bittyVault.migrate();

        // Verify all assets are transferred to next vault
        assertEq(mockWBTC.balanceOf(address(bittyVault)), 0, "WBTC should be transferred");
        assertEq(
            mockWBTC.balanceOf(address(nextVault)), nextVaultWbtcBefore + wbtcAmount, "WBTC should be in next vault"
        );

        assertEq(mockWETH.balanceOf(address(bittyVault)), 0, "WETH should be transferred");
        assertEq(
            mockWETH.balanceOf(address(nextVault)), nextVaultWethBefore + wethAmount, "WETH should be in next vault"
        );

        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0, "USDT should be transferred");
        assertEq(
            mockUSDT.balanceOf(address(nextVault)), nextVaultUsdtBefore + usdtAmount, "USDT should be in next vault"
        );

        assertEq(mockUSDC.balanceOf(address(bittyVault)), 0, "USDC should be transferred");
        assertEq(
            mockUSDC.balanceOf(address(nextVault)), nextVaultUsdcBefore + usdcAmount, "USDC should be in next vault"
        );

        assertEq(address(bittyVault).balance, 0, "ETH should be transferred");
        assertEq(address(nextVault).balance, nextVaultEthBefore + ethAmount, "ETH should be in next vault");
    }

    function test_MigrateFailsIfNotTrustee() public {
        address nonTrustee = makeAddr("nonTrustee");
        vm.expectRevert("Only trustee");
        vm.prank(nonTrustee);
        bittyVault.migrate();
    }

    function test_MigrateFailsIfNotInitialized() public {
        BittyVault newVault = new BittyVault();
        address newTrustee = makeAddr("newTrustee");
        vm.expectRevert("Trust not initialized");
        vm.prank(newTrustee);
        newVault.migrate();
    }

    function test_MigrateFailsIfNextVaultIsZero() public {
        // Set nextVault to zero address
        migrator.setNextVault(address(bittyVault), address(0));

        vm.expectRevert(AddressZero.selector);
        vm.prank(trustee);
        bittyVault.migrate();
    }

    function test_MigrateWithEmptyBalances() public {
        // Migrate without adding any assets to vault
        vm.prank(trustee);
        bittyVault.migrate();

        // Verify all balances are 0
        assertEq(mockWBTC.balanceOf(address(bittyVault)), 0);
        assertEq(mockWETH.balanceOf(address(bittyVault)), 0);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0);
        assertEq(mockUSDC.balanceOf(address(bittyVault)), 0);
        assertEq(address(bittyVault).balance, 0);
    }

    function test_MigrateOnlyTransfersAssetsInSet() public {
        // Create a token not in asset list
        MockERC20 randomToken = new MockERC20("RANDOM", "RANDOM", 18);
        uint256 randomAmount = 100 ether;
        deal(address(randomToken), address(bittyVault), randomAmount);

        // Give current vault some assets in the list
        uint256 wbtcAmount = 1 ether;
        deal(address(mockWBTC), address(bittyVault), wbtcAmount);

        // Execute migration
        vm.prank(trustee);
        bittyVault.migrate();

        // Verify assets in list are transferred
        assertEq(mockWBTC.balanceOf(address(bittyVault)), 0, "WBTC should be transferred");
        assertEq(mockWBTC.balanceOf(address(nextVault)), wbtcAmount, "WBTC should be in next vault");

        // Verify tokens not in list are not transferred (because _revoke only transfers assets in _assets and _stableCoins)
        assertEq(randomToken.balanceOf(address(bittyVault)), randomAmount, "Random token should remain");
    }
}

