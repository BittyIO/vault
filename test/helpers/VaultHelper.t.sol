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
    function getMoneyFromYieldProvider(address[] memory _yieldProviders, address stableCoinAddress, uint256 amount)
        external
        returns (uint256)
    {
        return VaultHelper.getMoneyFromYieldProvider(_yieldProviders, stableCoinAddress, amount);
    }

    function getMoneyFromSwapProvider(
        IPoolManager poolManager,
        address[] memory _swapProviders,
        address[] memory _assets,
        address stableCoinAddress,
        uint256 amount
    ) external returns (uint256) {
        return VaultHelper.getMoneyFromSwapProvider(
            poolManager, address(this), _swapProviders, _assets, stableCoinAddress, amount
        );
    }

    function getMoney(
        IPoolManager poolManager,
        address[] memory yieldProviders,
        address[] memory swapProviders,
        address[] memory assets,
        uint256 amount,
        address stableCoinAddress,
        address to
    ) external {
        VaultHelper.getMoney(
            address(this), poolManager, yieldProviders, swapProviders, assets, amount, stableCoinAddress, to
        );
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

        yieldProvider1 = new MockYieldProvider();
        yieldProvider2 = new MockYieldProvider();
        swapProvider = new MockSwapProvider();
        poolManager = IPoolManager(makeAddr("poolManager"));

        recipient = makeAddr("recipient");
    }

    function test_GetMoneyFromYieldProvider_SingleProviderEnough() public {
        uint256 amount = 1000 * 1e6;
        deal(address(mockUSDT), address(vault), amount);

        vm.startPrank(address(vault));
        mockUSDT.approve(address(yieldProvider1), amount);
        yieldProvider1.supply(address(mockUSDT), amount);
        vm.stopPrank();

        address[] memory providers = new address[](1);
        providers[0] = address(yieldProvider1);

        uint256 withdrawn = vault.getMoneyFromYieldProvider(providers, address(mockUSDT), amount);

        assertEq(withdrawn, amount, "Should withdraw full amount");
        assertEq(mockUSDT.balanceOf(address(vault)), amount, "Vault should receive tokens");
        assertEq(yieldProvider1.getBalance(address(mockUSDT)), 0, "Provider should have no balance");
    }

    function test_GetMoneyFromYieldProvider_MultipleProviders() public {
        uint256 amount = 1000 * 1e6;
        uint256 provider1Amount = 600 * 1e6;
        uint256 provider2Amount = 500 * 1e6;

        deal(address(mockUSDT), address(vault), provider1Amount + provider2Amount);
        vm.startPrank(address(vault));
        mockUSDT.approve(address(yieldProvider1), provider1Amount);
        mockUSDT.approve(address(yieldProvider2), provider2Amount);
        yieldProvider1.supply(address(mockUSDT), provider1Amount);
        yieldProvider2.supply(address(mockUSDT), provider2Amount);
        vm.stopPrank();

        address[] memory providers = new address[](2);
        providers[0] = address(yieldProvider1);
        providers[1] = address(yieldProvider2);

        uint256 withdrawn = vault.getMoneyFromYieldProvider(providers, address(mockUSDT), amount);

        assertEq(withdrawn, amount, "Should withdraw requested amount");
        assertEq(mockUSDT.balanceOf(address(vault)), amount, "Vault should receive tokens");
        assertEq(yieldProvider1.getBalance(address(mockUSDT)), 0, "Provider1 should be empty");
        assertEq(
            yieldProvider2.getBalance(address(mockUSDT)),
            provider2Amount - (amount - provider1Amount),
            "Provider2 should have remaining"
        );
    }

    function test_GetMoneyFromYieldProvider_EmptyProviders() public {
        address[] memory providers = new address[](0);
        uint256 withdrawn = vault.getMoneyFromYieldProvider(providers, address(mockUSDT), 1000 * 1e6);
        assertEq(withdrawn, 0, "Should return 0 with no providers");
    }

    function test_GetMoneyFromYieldProvider_ProviderWithZeroBalance() public {
        address[] memory providers = new address[](1);
        providers[0] = address(yieldProvider1);

        uint256 withdrawn = vault.getMoneyFromYieldProvider(providers, address(mockUSDT), 1000 * 1e6);
        assertEq(withdrawn, 0, "Should return 0 when provider has no balance");
    }

    function test_GetMoneyFromYieldProvider_InsufficientBalance() public {
        uint256 available = 500 * 1e6;
        uint256 requested = 1000 * 1e6;

        deal(address(mockUSDT), address(vault), available);
        vm.prank(address(vault));
        mockUSDT.approve(address(yieldProvider1), available);
        vm.prank(address(vault));
        yieldProvider1.supply(address(mockUSDT), available);

        address[] memory providers = new address[](1);
        providers[0] = address(yieldProvider1);

        uint256 withdrawn = vault.getMoneyFromYieldProvider(providers, address(mockUSDT), requested);

        assertEq(withdrawn, available, "Should withdraw all available");
        assertEq(mockUSDT.balanceOf(address(vault)), available, "Vault should receive all available");
    }

    function test_GetMoney_SufficientBalance() public {
        uint256 amount = 1000;
        uint256 decimals = mockUSDT.decimals();
        uint256 withdrawAmount = amount * 10 ** decimals;

        deal(address(mockUSDT), address(vault), withdrawAmount);

        address[] memory yieldProviders = new address[](0);
        address[] memory swapProviders = new address[](0);
        address[] memory assets = new address[](0);

        vault.getMoney(poolManager, yieldProviders, swapProviders, assets, amount, address(mockUSDT), recipient);

        assertEq(mockUSDT.balanceOf(recipient), withdrawAmount, "Recipient should receive full amount");
        assertEq(mockUSDT.balanceOf(address(vault)), 0, "Vault should have no balance");
    }

    function test_GetMoney_NeedsYieldProvider() public {
        uint256 amount = 1000;
        uint256 decimals = mockUSDT.decimals();
        uint256 withdrawAmount = amount * 10 ** decimals;
        uint256 vaultBalance = withdrawAmount / 2;
        uint256 needed = withdrawAmount - vaultBalance;

        deal(address(mockUSDT), address(vault), vaultBalance + needed);
        vm.startPrank(address(vault));
        mockUSDT.approve(address(yieldProvider1), needed);
        yieldProvider1.supply(address(mockUSDT), needed);
        vm.stopPrank();

        address[] memory yieldProviders = new address[](1);
        yieldProviders[0] = address(yieldProvider1);
        address[] memory swapProviders = new address[](0);
        address[] memory assets = new address[](0);

        vault.getMoney(poolManager, yieldProviders, swapProviders, assets, amount, address(mockUSDT), recipient);

        assertEq(mockUSDT.balanceOf(recipient), withdrawAmount, "Recipient should receive full amount");
        assertEq(mockUSDT.balanceOf(address(vault)), 0, "Vault should have no balance");
    }

    function test_GetMoney_InsufficientStablecoinBalance() public {
        uint256 amount = 1000;
        uint256 decimals = mockUSDT.decimals();
        uint256 withdrawAmount = amount * 10 ** decimals;
        uint256 vaultBalance = withdrawAmount / 2;

        deal(address(mockUSDT), address(vault), vaultBalance);

        address[] memory yieldProviders = new address[](0);
        address[] memory swapProviders = new address[](0);
        address[] memory assets = new address[](0);

        vm.expectRevert(InsufficientStablecoinBalance.selector);
        vault.getMoney(poolManager, yieldProviders, swapProviders, assets, amount, address(mockUSDT), recipient);
    }

    function test_GetMoney_InsufficientEvenWithSwapProviders() public {
        uint256 amount = 1000;
        uint256 decimals = mockUSDT.decimals();
        uint256 withdrawAmount = amount * 10 ** decimals;
        uint256 vaultBalance = withdrawAmount / 2;

        deal(address(mockUSDT), address(vault), vaultBalance);
        deal(address(mockWBTC), address(vault), 100 * 1e8);

        vm.startPrank(address(vault));
        mockWBTC.approve(address(swapProvider), type(uint256).max);
        vm.stopPrank();

        address[] memory yieldProviders = new address[](0);
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = address(swapProvider);
        address[] memory assets = new address[](1);
        assets[0] = address(mockWBTC);

        // Mock poolManager to return 0 for quotes (no pool found)
        // This will cause getMoneyFromSwapProvider to return 0, leading to InsufficientStablecoinBalance
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.extsload.selector), abi.encode(bytes32(0))
        );

        vm.expectRevert(InsufficientStablecoinBalance.selector);
        vault.getMoney(poolManager, yieldProviders, swapProviders, assets, amount, address(mockUSDT), recipient);
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

    function test_GetMoneyFromSwapProvider_EmptySwapProviders() public {
        address[] memory swapProviders = new address[](0);
        address[] memory assets = new address[](1);
        assets[0] = address(mockWBTC);

        uint256 swapped =
            vault.getMoneyFromSwapProvider(poolManager, swapProviders, assets, address(mockUSDT), 1000 * 1e6);
        assertEq(swapped, 0, "Should return 0 with no swap providers");
    }

    function test_GetMoneyFromSwapProvider_EmptyAssets() public {
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = address(swapProvider);
        address[] memory assets = new address[](0);

        uint256 swapped =
            vault.getMoneyFromSwapProvider(poolManager, swapProviders, assets, address(mockUSDT), 1000 * 1e6);
        assertEq(swapped, 0, "Should return 0 with no assets");
    }

    function test_GetMoneyFromSwapProvider_AssetWithZeroBalance() public {
        address[] memory swapProviders = new address[](1);
        swapProviders[0] = address(swapProvider);
        address[] memory assets = new address[](1);
        assets[0] = address(mockWBTC);

        uint256 swapped =
            vault.getMoneyFromSwapProvider(poolManager, swapProviders, assets, address(mockUSDT), 1000 * 1e6);
        assertEq(swapped, 0, "Should return 0 when asset has zero balance");
    }
}

