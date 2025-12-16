// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {VaultHelper} from "../../src/helpers/VaultHelper.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {MockYieldProvider} from "../mock/MockYieldProvider.sol";
import {MockSwapProvider} from "../mock/MockSwapProvider.sol";
import {TransferFailed, InsufficientStablecoinBalance} from "../../src/interfaces/Errors.sol";
import {IPoolManager} from "../../src/libs/uniswap/v4/Uniswap.sol";
import {ISwapProvider} from "../../src/interfaces/IAssetManager.sol";

contract MockVaultForTesting {
    function getMoney(uint256 amount, address stableCoinAddress, address to) external {
        VaultHelper.getMoney(address(this), amount, stableCoinAddress, to);
    }

    function getPercentageMoney(address[] memory stableCoins, address[] memory assets, uint256 percentage, address to)
        external
    {
        VaultHelper.getPercentageMoney(address(this), stableCoins, assets, percentage, to);
    }
}

contract VaultHelperTest is Test {
    MockVaultForTesting public vault;
    MockERC20 public mockUSDT;
    MockERC20 public mockUSDC;
    MockERC20 public mockWBTC;
    MockERC20 public mockWETH;
    MockYieldProvider public yieldProvider1;
    MockYieldProvider public yieldProvider2;
    MockSwapProvider public swapProvider;
    IPoolManager public poolManager;

    address public recipient;

    function setUp() public {
        vault = new MockVaultForTesting();
        mockUSDT = new MockERC20("Tether USD", "USDT", 6);
        mockUSDC = new MockERC20("USD Coin", "USDC", 6);
        mockWBTC = new MockERC20("Wrapped BTC", "WBTC", 8);
        mockWETH = new MockERC20("Wrapped Ether", "WETH", 18);

        recipient = makeAddr("recipient");
    }

    function test_GetMoney_SufficientBalance() public {
        uint256 amount = 1000;
        uint256 decimals = mockUSDT.decimals();
        uint256 withdrawAmount = amount * 10 ** decimals;

        deal(address(mockUSDT), address(vault), withdrawAmount);

        vault.getMoney(amount, address(mockUSDT), recipient);

        assertEq(mockUSDT.balanceOf(recipient), withdrawAmount, "Recipient should receive full amount");
        assertEq(mockUSDT.balanceOf(address(vault)), 0, "Vault should have no balance");
    }

    function test_GetMoney_InsufficientStablecoinBalance() public {
        uint256 amount = 1000;
        uint256 decimals = mockUSDT.decimals();
        uint256 withdrawAmount = amount * 10 ** decimals;
        uint256 vaultBalance = withdrawAmount / 2;

        deal(address(mockUSDT), address(vault), vaultBalance);
        vm.expectRevert(InsufficientStablecoinBalance.selector);
        vault.getMoney(amount, address(mockUSDT), recipient);
    }

    function test_GetPercentageMoney_StableCoins() public {
        uint256 percentage = 5000;
        deal(address(mockUSDT), address(vault), 1000 * 1e6);
        deal(address(mockUSDC), address(vault), 2000 * 1e6);

        address[] memory stableCoins = new address[](2);
        stableCoins[0] = address(mockUSDT);
        stableCoins[1] = address(mockUSDC);
        address[] memory assets = new address[](0);

        vault.getPercentageMoney(stableCoins, assets, percentage, recipient);

        assertEq(mockUSDT.balanceOf(recipient), 500 * 1e6, "Should transfer 50% of USDT");
        assertEq(mockUSDC.balanceOf(recipient), 1000 * 1e6, "Should transfer 50% of USDC");
        assertEq(mockUSDT.balanceOf(address(vault)), 500 * 1e6, "Vault should keep 50% of USDT");
        assertEq(mockUSDC.balanceOf(address(vault)), 1000 * 1e6, "Vault should keep 50% of USDC");
    }

    function test_GetPercentageMoney_Assets() public {
        uint256 percentage = 2500;
        deal(address(mockWBTC), address(vault), 1000 * 1e8);
        deal(address(mockWETH), address(vault), 2000 * 1e18);

        address[] memory stableCoins = new address[](0);
        address[] memory assets = new address[](2);
        assets[0] = address(mockWBTC);
        assets[1] = address(mockWETH);

        vault.getPercentageMoney(stableCoins, assets, percentage, recipient);

        assertEq(mockWBTC.balanceOf(recipient), 250 * 1e8, "Should transfer 25% of WBTC");
        assertEq(mockWETH.balanceOf(recipient), 500 * 1e18, "Should transfer 25% of WETH");
    }

    function test_GetPercentageMoney_ZeroBalance() public {
        address[] memory stableCoins = new address[](1);
        stableCoins[0] = address(mockUSDT);
        address[] memory assets = new address[](0);

        vault.getPercentageMoney(stableCoins, assets, 5000, recipient);
        assertEq(mockUSDT.balanceOf(recipient), 0, "Should transfer nothing");
    }

    function test_GetPercentageMoney_ZeroPercentage() public {
        deal(address(mockUSDT), address(vault), 1000 * 1e6);

        address[] memory stableCoins = new address[](1);
        stableCoins[0] = address(mockUSDT);
        address[] memory assets = new address[](0);

        vault.getPercentageMoney(stableCoins, assets, 0, recipient);
        assertEq(mockUSDT.balanceOf(recipient), 0, "Should transfer nothing with 0%");
    }
}
