// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {Factory} from "../../src/Factory.sol";
import {WhiteList} from "whitelist-contracts/src/WhiteList.sol";
import {AaveV3Provider} from "provider-contracts/src/providers/AaveV3Provider.sol";
import {LidoV2Provider} from "provider-contracts/src/providers/LidoV2Provider.sol";
import {mainnet} from "provider-contracts/script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {UniswapV3Provider} from "provider-contracts/src/providers/UniswapV3Provider.sol";
import {Path} from "provider-contracts/src/libs/uniswap/v3/Uniswap.sol";
import {IAssetManager} from "../../src/interfaces/IAssetManager.sol";

/// @notice Mainnet fork integration tests for Vault with real Aave and Lido providers.
contract TestVaultFork is Test {
    using SafeERC20 for IERC20;
    using Path for bytes;

    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    Vault public vaultImpl;
    Vault public vault;
    Factory public factory;
    WhiteList public whiteList;
    AaveV3Provider public aaveProvider;
    LidoV2Provider public lidoProvider;
    UniswapV3Provider public uniswapV3Provider;
    address public assetManager;

    address[] public assets;
    address[] public stableCoins;
    address[] public lendingProviders;
    address[] public stakingProviders;
    address[] public ammProviders;

    function setUp() public {
        vm.createSelectFork("mainnet");

        whiteList = new WhiteList();
        vm.startPrank(tx.origin);
        whiteList.grantRole(whiteList.ASSET_MANAGER_ROLE(), tx.origin);
        whiteList.grantRole(whiteList.STABLE_COIN_MANAGER_ROLE(), tx.origin);
        whiteList.grantRole(whiteList.LENDING_MANAGER_ROLE(), tx.origin);
        whiteList.grantRole(whiteList.STAKING_MANAGER_ROLE(), tx.origin);
        whiteList.grantRole(whiteList.AMM_MANAGER_ROLE(), tx.origin);
        whiteList.addAssets(_arr(mainnet.WETH, WBTC));
        whiteList.addStableCoins(_arr(mainnet.USDC, mainnet.USDT));

        aaveProvider = new AaveV3Provider(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER);
        aaveProvider.initialize(address(this));
        whiteList.addLendingProviders(_arr(address(aaveProvider)));

        lidoProvider = new LidoV2Provider(mainnet.STETH, mainnet.UNSTETH, mainnet.WETH);
        lidoProvider.initialize(address(this));
        whiteList.addStakingProviders(_arr(address(lidoProvider)));

        uniswapV3Provider =
            new UniswapV3Provider(mainnet.UNISWAP_V3_ROUTER, mainnet.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER);
        uniswapV3Provider.initialize(address(this));
        whiteList.addAMMProviders(_arr(address(uniswapV3Provider)));
        vm.stopPrank();

        assets = _arr(mainnet.WETH, WBTC);
        stableCoins = _arr(mainnet.USDC, mainnet.USDT);
        lendingProviders = _arr(address(aaveProvider));
        stakingProviders = _arr(address(lidoProvider));
        ammProviders = _arr(address(uniswapV3Provider));

        vaultImpl = new Vault();
        factory = new Factory();
        factory.initialize(address(vaultImpl), address(whiteList), makeAddr("subscription"), mainnet.WETH);

        address vaultAddr = factory.deployVault(assets, stableCoins, lendingProviders, stakingProviders, ammProviders);
        vault = Vault(payable(vaultAddr));

        assetManager = address(this);
        vm.prank(tx.origin);
        vault.setAssetManager(assetManager);
    }

    function _arr(address a, address b) internal pure returns (address[] memory) {
        address[] memory arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function _arr(address a) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = a;
        return arr;
    }

    function test_VaultDeployAndInitialize() public view {
        assertEq(vault.owner(), tx.origin);
        assertEq(vault.assetManager(), assetManager);
        assertEq(vault.wethAddress(), mainnet.WETH);

        address[] memory lending = vault.getLendingProviders();
        assertEq(lending.length, 1);
        assertEq(lending[0], address(aaveProvider));

        address[] memory staking = vault.getStakingProviders();
        assertEq(staking.length, 1);
        assertEq(staking[0], address(lidoProvider));
    }

    function test_SupplyToAave() public {
        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(vault), amount);

        uint256 balanceBefore = vault.getSuppliedBalance(address(aaveProvider), mainnet.WETH);
        assertEq(balanceBefore, 0);

        vm.prank(assetManager);
        vault.supply(address(aaveProvider), mainnet.WETH, amount);

        uint256 balanceAfter = vault.getSuppliedBalance(address(aaveProvider), mainnet.WETH);
        assertApproxEqAbs(balanceAfter, amount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);
    }

    function test_WithdrawFromAave() public {
        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(vault), supplyAmount);
        vm.prank(assetManager);
        vault.supply(address(aaveProvider), mainnet.WETH, supplyAmount);

        uint256 withdrawAmount = 0.5 ether;
        uint256 vaultBalanceBefore = IERC20(mainnet.WETH).balanceOf(address(vault));

        vm.prank(assetManager);
        vault.withdraw(address(aaveProvider), mainnet.WETH, withdrawAmount);

        uint256 vaultBalanceAfter = IERC20(mainnet.WETH).balanceOf(address(vault));
        assertApproxEqAbs(vaultBalanceAfter - vaultBalanceBefore, withdrawAmount, 5);

        uint256 remaining = vault.getSuppliedBalance(address(aaveProvider), mainnet.WETH);
        assertApproxEqAbs(remaining, supplyAmount - withdrawAmount, 10);
    }

    function test_StakeToLido() public {
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(vault), stakeAmount);

        uint256 stakingBalanceBefore = vault.getStakedBalance(address(lidoProvider), mainnet.WETH);

        vm.prank(assetManager);
        vault.stake(address(lidoProvider), mainnet.WETH, stakeAmount);

        uint256 stakingBalanceAfter = vault.getStakedBalance(address(lidoProvider), mainnet.WETH);
        assertGt(stakingBalanceAfter, stakingBalanceBefore);
        assertApproxEqAbs(stakingBalanceAfter - stakingBalanceBefore, stakeAmount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);
    }

    function test_UnstakeFromLido() public {
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(vault), stakeAmount);
        vm.prank(assetManager);
        vault.stake(address(lidoProvider), mainnet.WETH, stakeAmount);

        uint256 unstakeAmount = 0.05 ether;
        vm.prank(assetManager);
        vault.unstake(address(lidoProvider), mainnet.WETH, unstakeAmount);

        uint256[] memory ids = vault.getUnstakeRequestIds(address(lidoProvider));
        assertEq(ids.length, 1);
    }

    function test_ClaimFromLido() public {
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(vault), stakeAmount);
        vm.prank(assetManager);
        vault.stake(address(lidoProvider), mainnet.WETH, stakeAmount);

        uint256 unstakeAmount = 0.05 ether;
        vm.prank(assetManager);
        vault.unstake(address(lidoProvider), mainnet.WETH, unstakeAmount);

        uint256[] memory ids = vault.getUnstakeRequestIds(address(lidoProvider));
        assertEq(ids.length, 1);

        vm.prank(assetManager);
        vault.claimUnstaked(address(lidoProvider), ids);
        // On mainnet fork, Lido withdrawals are not finalized immediately, so request ids remain
        uint256[] memory remaining = vault.getUnstakeRequestIds(address(lidoProvider));
        assertEq(remaining.length, 1);
    }

    function test_SupplyAndWithdrawFullCycle() public {
        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(vault), amount);

        vm.prank(assetManager);
        vault.supply(address(aaveProvider), mainnet.WETH, amount);

        uint256 lendingBalance = vault.getSuppliedBalance(address(aaveProvider), mainnet.WETH);
        vm.prank(assetManager);
        vault.withdraw(address(aaveProvider), mainnet.WETH, lendingBalance);

        assertApproxEqAbs(IERC20(mainnet.WETH).balanceOf(address(vault)), amount, 5);
        assertEq(vault.getSuppliedBalance(address(aaveProvider), mainnet.WETH), 0);
    }

    function test_Receive_acceptsPlainEthTransfer() public {
        uint256 amount = 0.1 ether;
        address depositor = makeAddr("ethDepositor");

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success, bytes memory returnData) = address(vault).call{value: amount}("");

        assertTrue(success, string(returnData));
        assertEq(address(vault).balance, amount);
    }

    function test_ETHToWETH() public {
        uint256 amount = 1 ether;
        vm.deal(address(vault), amount);

        vm.prank(assetManager);
        vault.ETHToWETH(amount);

        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), amount);
        assertEq(address(vault).balance, 0);
    }

    function test_ethDeposit_viaReceive_thenETHToWETH() public {
        uint256 amount = 0.1 ether;
        address depositor = makeAddr("ethDepositor");

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success,) = address(vault).call{value: amount}("");
        assertTrue(success);
        assertEq(address(vault).balance, amount);

        vm.prank(assetManager);
        vault.ETHToWETH(amount);

        assertEq(address(vault).balance, 0);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), amount);
    }

    function test_RevertSupplyWhenNotAssetManager() public {
        deal(mainnet.WETH, address(vault), 1 ether);
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        vault.supply(address(aaveProvider), mainnet.WETH, 1 ether);
    }

    function test_FactoryComputeVaultAddress() public view {
        address computed = factory.computeVaultAddress(address(this));
        assertEq(computed, address(vault));
    }

    function test_FactoryRevertWhenVaultAlreadyDeployed() public {
        vm.expectRevert();
        factory.deployVault(assets, stableCoins, lendingProviders, stakingProviders, ammProviders);
    }

    function test_RebalanceWETHToUSDT() public {
        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(vault), sellAmount);

        IAssetManager.RebalanceConfig memory config =
            IAssetManager.RebalanceConfig({minimalBalance: 0, minimalDuration: 0, maxAmount: 0});
        vm.prank(tx.origin);
        vault.setRebalanceConfig(mainnet.WETH, config);

        address[] memory path = new address[](2);
        path[0] = mainnet.WETH;
        path[1] = mainnet.USDT;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 buyAmountMin = 1;
        bytes memory swapData = abi.encode(mainnet.WETH, sellAmount, mainnet.USDT, buyAmountMin, encodedPath);

        uint256 usdtBefore = IERC20(mainnet.USDT).balanceOf(address(vault));
        vm.prank(assetManager);
        vault.rebalance(address(uniswapV3Provider), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);
        uint256 usdtAfter = IERC20(mainnet.USDT).balanceOf(address(vault));
        assertGt(usdtAfter, usdtBefore);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);
    }

    function test_AddReceiverAndPayReceiver() public {
        deal(mainnet.USDC, address(vault), 1000e6);

        IVault.Receiver memory receiver = IVault.Receiver({
            receiverAddress: address(this),
            trigger: address(0),
            assetAddress: mainnet.USDC,
            amount: 100e6,
            paymentCount: 1,
            startTimestamp: block.timestamp,
            durationTimestamp: 1 days,
            isImmutable: false
        });

        vm.prank(tx.origin);
        vault.addReceiver("test", receiver);

        vm.warp(block.timestamp + 8 days);

        uint256 balanceBefore = IERC20(mainnet.USDC).balanceOf(address(this));
        vault.payReceiver("test");
        uint256 balanceAfter = IERC20(mainnet.USDC).balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, 100e6);
    }

    function test_AssetManagerWithdrawFromAaveAndPayReceiverInOneBlock() public {
        uint256 supplyAmount = 1 ether;
        uint256 payAmount = 0.5 ether;
        address receiverAddr = makeAddr("receiverBeneficiary");

        deal(mainnet.WETH, address(vault), supplyAmount);
        vm.prank(assetManager);
        vault.supply(address(aaveProvider), mainnet.WETH, supplyAmount);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);

        IVault.Receiver memory receiver = IVault.Receiver({
            receiverAddress: receiverAddr,
            trigger: address(0),
            assetAddress: mainnet.WETH,
            amount: payAmount,
            paymentCount: 1,
            startTimestamp: block.timestamp,
            durationTimestamp: 1 days,
            isImmutable: false
        });
        vm.prank(tx.origin);
        vault.addReceiver("salary", receiver);
        vm.warp(block.timestamp + 1 days);

        uint256 receiverBefore = IERC20(mainnet.WETH).balanceOf(receiverAddr);

        vault.withdraw(address(aaveProvider), mainnet.WETH, payAmount);
        vault.payReceiver("salary");

        uint256 receiverAfter = IERC20(mainnet.WETH).balanceOf(receiverAddr);
        assertEq(receiverAfter - receiverBefore, payAmount);

        uint256 remaining = vault.getSuppliedBalance(address(aaveProvider), mainnet.WETH);
        assertGe(remaining, supplyAmount - payAmount);
    }
}
