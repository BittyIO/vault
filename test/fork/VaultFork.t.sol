// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {BittyVault} from "../../src/BittyVault.sol";
import {BittyVaultFactory} from "../../src/BittyVaultFactory.sol";
import {BittyGuard} from "guard-contracts/src/BittyGuard.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";
import {LidoV2Protocol} from "protocol-contracts/src/protocols/LidoV2Protocol.sol";
import {mainnet} from "protocol-contracts/script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {UniswapV3Protocol} from "protocol-contracts/src/protocols/UniswapV3Protocol.sol";
import {Path} from "protocol-contracts/src/libs/uniswap/v3/Uniswap.sol";
import {IAssetManager, RebalanceInMinimalTime} from "../../src/interfaces/IAssetManager.sol";

/// @notice Mainnet fork integration tests for BittyVault with real Aave and Lido providers.
contract TestVaultFork is Test {
    using SafeERC20 for IERC20;
    using Path for bytes;

    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    BittyVault public vaultImpl;
    BittyVault public vault;
    BittyVaultFactory public factory;
    BittyGuard public guard;
    AaveV3Protocol public aaveProtocol;
    LidoV2Protocol public lidoProtocol;
    UniswapV3Protocol public uniswapV3Protocol;
    address public assetManager;

    address[] public assets;
    address[] public vaultAssets;
    address[] public lendingProtocols;
    address[] public stakingProtocols;
    address[] public ammProtocols;

    function setUp() public {
        vm.createSelectFork("mainnet");

        guard = new BittyGuard();
        vm.startPrank(tx.origin);
        guard.grantRole(guard.ASSET_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.STABLE_COIN_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.LENDING_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.STAKING_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.AMM_MANAGER_ROLE(), tx.origin);
        guard.addAssets(_arr(mainnet.WETH, WBTC));
        guard.addStableCoins(_arr(mainnet.USDC, mainnet.USDT));

        aaveProtocol = new AaveV3Protocol(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER);
        aaveProtocol.initialize(address(this));
        guard.addLendingProtocols(_arr(address(aaveProtocol)));

        lidoProtocol = new LidoV2Protocol(mainnet.STETH, mainnet.UNSTETH, mainnet.WETH);
        lidoProtocol.initialize(address(this));
        guard.addStakingProtocols(_arr(address(lidoProtocol)));

        uniswapV3Protocol = new UniswapV3Protocol(
            mainnet.UNISWAP_V3_ROUTER, mainnet.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, address(guard)
        );
        uniswapV3Protocol.initialize(address(this));
        guard.addAMMProtocols(_arr(address(uniswapV3Protocol)));
        vm.stopPrank();

        assets = _arr(mainnet.WETH, WBTC);
        vaultAssets = new address[](4);
        vaultAssets[0] = mainnet.WETH;
        vaultAssets[1] = WBTC;
        vaultAssets[2] = mainnet.USDC;
        vaultAssets[3] = mainnet.USDT;
        lendingProtocols = _arr(address(aaveProtocol));
        stakingProtocols = _arr(address(lidoProtocol));
        ammProtocols = _arr(address(uniswapV3Protocol));

        vaultImpl = new BittyVault();
        factory = new BittyVaultFactory();
        factory.initialize(address(vaultImpl), address(guard), mainnet.WETH);

        assetManager = address(this);
        address vaultAddr = factory.deployVaultWithSelected(
            tx.origin,
            "main",
            _assetManagers(assetManager),
            vaultAssets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols
        );
        vault = BittyVault(payable(vaultAddr));
    }

    function _assetManagers(address manager) internal pure returns (address[] memory managers) {
        managers = new address[](1);
        managers[0] = manager;
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
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), tx.origin));
        assertEq(vault.wethAddress(), mainnet.WETH);

        address[] memory lending = vault.getLendingProtocols();
        assertEq(lending.length, 1);
        assertEq(lending[0], address(aaveProtocol));

        address[] memory staking = vault.getStakingProtocols();
        assertEq(staking.length, 1);
        assertEq(staking[0], address(lidoProtocol));
    }

    function test_SupplyToAave() public {
        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(vault), amount);

        uint256 balanceBefore = vault.getSuppliedBalance(address(aaveProtocol), mainnet.WETH);
        assertEq(balanceBefore, 0);

        vault.supply(address(aaveProtocol), mainnet.WETH, amount);

        uint256 balanceAfter = vault.getSuppliedBalance(address(aaveProtocol), mainnet.WETH);
        assertApproxEqAbs(balanceAfter, amount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);
    }

    function test_WithdrawFromAave() public {
        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(vault), supplyAmount);
        vault.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);

        uint256 withdrawAmount = 0.5 ether;
        uint256 vaultBalanceBefore = IERC20(mainnet.WETH).balanceOf(address(vault));

        vault.withdraw(address(aaveProtocol), mainnet.WETH, withdrawAmount);

        uint256 vaultBalanceAfter = IERC20(mainnet.WETH).balanceOf(address(vault));
        assertApproxEqAbs(vaultBalanceAfter - vaultBalanceBefore, withdrawAmount, 5);

        uint256 remaining = vault.getSuppliedBalance(address(aaveProtocol), mainnet.WETH);
        assertApproxEqAbs(remaining, supplyAmount - withdrawAmount, 10);
    }

    function test_StakeToLido() public {
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(vault), stakeAmount);

        uint256 stakingBalanceBefore = vault.getStakedBalance(address(lidoProtocol), mainnet.WETH);

        vault.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        uint256 stakingBalanceAfter = vault.getStakedBalance(address(lidoProtocol), mainnet.WETH);
        assertGt(stakingBalanceAfter, stakingBalanceBefore);
        assertApproxEqAbs(stakingBalanceAfter - stakingBalanceBefore, stakeAmount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);
    }

    function test_UnstakeFromLido() public {
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(vault), stakeAmount);
        vault.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        uint256 unstakeAmount = 0.05 ether;
        vault.unstake(address(lidoProtocol), mainnet.WETH, unstakeAmount);

        uint256[] memory ids = vault.getUnstakeRequestIds(address(lidoProtocol));
        assertEq(ids.length, 1);
    }

    function test_ClaimFromLido() public {
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(vault), stakeAmount);
        vault.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        uint256 unstakeAmount = 0.05 ether;
        vault.unstake(address(lidoProtocol), mainnet.WETH, unstakeAmount);

        uint256[] memory ids = vault.getUnstakeRequestIds(address(lidoProtocol));
        assertEq(ids.length, 1);

        vault.claimUnstaked(address(lidoProtocol), ids);
        // On mainnet fork, Lido withdrawals are not finalized immediately, so request ids remain
        uint256[] memory remaining = vault.getUnstakeRequestIds(address(lidoProtocol));
        assertEq(remaining.length, 1);
    }

    function test_SupplyAndWithdrawFullCycle() public {
        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(vault), amount);

        vault.supply(address(aaveProtocol), mainnet.WETH, amount);

        uint256 lendingBalance = vault.getSuppliedBalance(address(aaveProtocol), mainnet.WETH);
        vault.withdraw(address(aaveProtocol), mainnet.WETH, lendingBalance);

        assertApproxEqAbs(IERC20(mainnet.WETH).balanceOf(address(vault)), amount, 5);
        assertEq(vault.getSuppliedBalance(address(aaveProtocol), mainnet.WETH), 0);
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

        vault.ETHToWETH(amount);

        assertEq(address(vault).balance, 0);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), amount);
    }

    function test_RevertSupplyWhenNotAssetManager() public {
        deal(mainnet.WETH, address(vault), 1 ether);
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        vault.supply(address(aaveProtocol), mainnet.WETH, 1 ether);
    }

    function test_FactoryComputeVaultAddress() public view {
        address computed = factory.computeVaultAddress(tx.origin, "main");
        assertEq(computed, address(vault));
    }

    function test_FactoryRevertWhenVaultAlreadyDeployed() public {
        vm.expectRevert();
        factory.deployVaultWithSelected(
            tx.origin,
            "main",
            _assetManagers(assetManager),
            vaultAssets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols
        );
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
        vault.rebalance(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);
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
            isImmutable: false,
            payWithInsufficientBalance: false
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
        vault.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);

        IVault.Receiver memory receiver = IVault.Receiver({
            receiverAddress: receiverAddr,
            trigger: address(0),
            assetAddress: mainnet.WETH,
            amount: payAmount,
            paymentCount: 1,
            startTimestamp: block.timestamp,
            durationTimestamp: 1 days,
            isImmutable: false,
            payWithInsufficientBalance: false
        });
        vm.prank(tx.origin);
        vault.addReceiver("salary", receiver);
        vm.warp(block.timestamp + 1 days);

        uint256 receiverBefore = IERC20(mainnet.WETH).balanceOf(receiverAddr);

        vault.withdraw(address(aaveProtocol), mainnet.WETH, payAmount);
        vault.payReceiver("salary");

        uint256 receiverAfter = IERC20(mainnet.WETH).balanceOf(receiverAddr);
        assertEq(receiverAfter - receiverBefore, payAmount);

        uint256 remaining = vault.getSuppliedBalance(address(aaveProtocol), mainnet.WETH);
        assertGe(remaining, supplyAmount - payAmount);
    }

    function test_Rebalance_firstTimeSucceedsWithMinimalDurationSet() public {
        // lastRebalanceTimestamp is 0 before first rebalance; cooldown must not block it
        IAssetManager.RebalanceConfig memory config =
            IAssetManager.RebalanceConfig({minimalBalance: 0, minimalDuration: 7 days, maxAmount: 0});
        vm.prank(tx.origin);
        vault.setRebalanceConfig(mainnet.WETH, config);

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(vault), sellAmount);

        address[] memory path = new address[](2);
        path[0] = mainnet.WETH;
        path[1] = mainnet.USDT;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        bytes memory swapData =
            abi.encode(mainnet.WETH, sellAmount, mainnet.USDT, uint256(1), Path.encodePath(path, fees));

        uint256 usdtBefore = IERC20(mainnet.USDT).balanceOf(address(vault));
        vault.rebalance(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, sellAmount, 1, swapData);
        assertGt(IERC20(mainnet.USDT).balanceOf(address(vault)), usdtBefore);
    }

    function test_Rebalance_cooldownBlocksSecondImmediately() public {
        uint256 minimalDuration = 7 days;
        IAssetManager.RebalanceConfig memory config =
            IAssetManager.RebalanceConfig({minimalBalance: 0, minimalDuration: minimalDuration, maxAmount: 0});
        vm.prank(tx.origin);
        vault.setRebalanceConfig(mainnet.WETH, config);

        address[] memory path = new address[](2);
        path[0] = mainnet.WETH;
        path[1] = mainnet.USDT;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        bytes memory swapData =
            abi.encode(mainnet.WETH, uint256(0.01 ether), mainnet.USDT, uint256(1), Path.encodePath(path, fees));

        deal(mainnet.WETH, address(vault), 1 ether);
        vault.rebalance(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, 0.01 ether, 1, swapData);

        deal(mainnet.WETH, address(vault), 0.01 ether);
        vm.expectRevert(RebalanceInMinimalTime.selector);
        vault.rebalance(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, 0.01 ether, 1, swapData);
    }

    function test_Rebalance_succeedsAfterCooldownElapsed() public {
        uint256 minimalDuration = 7 days;
        IAssetManager.RebalanceConfig memory config =
            IAssetManager.RebalanceConfig({minimalBalance: 0, minimalDuration: minimalDuration, maxAmount: 0});
        vm.prank(tx.origin);
        vault.setRebalanceConfig(mainnet.WETH, config);

        address[] memory path = new address[](2);
        path[0] = mainnet.WETH;
        path[1] = mainnet.USDT;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        bytes memory swapData =
            abi.encode(mainnet.WETH, uint256(0.01 ether), mainnet.USDT, uint256(1), Path.encodePath(path, fees));

        deal(mainnet.WETH, address(vault), 1 ether);
        vault.rebalance(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, 0.01 ether, 1, swapData);

        vm.warp(block.timestamp + minimalDuration + 1);
        deal(mainnet.WETH, address(vault), 0.01 ether);
        uint256 usdtBefore = IERC20(mainnet.USDT).balanceOf(address(vault));
        vault.rebalance(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, 0.01 ether, 1, swapData);
        assertGt(IERC20(mainnet.USDT).balanceOf(address(vault)), usdtBefore);
    }

    function test_MultiStep_rebalanceThenPayReceiverThenRebalance() public {
        deal(mainnet.WETH, address(vault), 1 ether);

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

        // Step 1: rebalance 0.3 WETH → USDT
        uint256 firstSell = 0.3 ether;
        vault.rebalance(
            address(uniswapV3Protocol),
            mainnet.WETH,
            mainnet.USDT,
            firstSell,
            1,
            abi.encode(mainnet.WETH, firstSell, mainnet.USDT, uint256(1), encodedPath)
        );
        assertGt(IERC20(mainnet.USDT).balanceOf(address(vault)), 0);
        assertApproxEqAbs(IERC20(mainnet.WETH).balanceOf(address(vault)), 0.7 ether, 10);

        // Step 2: add WETH receiver and pay
        address receiverAddr = makeAddr("recipient");
        IVault.Receiver memory receiver = IVault.Receiver({
            receiverAddress: receiverAddr,
            trigger: address(0),
            assetAddress: mainnet.WETH,
            amount: 0.5 ether,
            paymentCount: 1,
            startTimestamp: block.timestamp,
            durationTimestamp: 0,
            isImmutable: false,
            payWithInsufficientBalance: false
        });
        vm.prank(tx.origin);
        vault.addReceiver("recipient", receiver);
        vault.payReceiver("recipient");
        assertEq(IERC20(mainnet.WETH).balanceOf(receiverAddr), 0.5 ether);

        // Step 3: rebalance remaining WETH → USDT
        uint256 remainingWeth = IERC20(mainnet.WETH).balanceOf(address(vault));
        assertGt(remainingWeth, 0);
        uint256 usdtBefore = IERC20(mainnet.USDT).balanceOf(address(vault));
        vault.rebalance(
            address(uniswapV3Protocol),
            mainnet.WETH,
            mainnet.USDT,
            remainingWeth,
            1,
            abi.encode(mainnet.WETH, remainingWeth, mainnet.USDT, uint256(1), encodedPath)
        );
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);
        assertGt(IERC20(mainnet.USDT).balanceOf(address(vault)), usdtBefore);
    }

    function test_DeployVault_customOwner() public {
        address customOwner = makeAddr("customVaultOwner");
        address customAssetManager = makeAddr("customAssetManager");
        address vaultAddr = factory.deployVaultWithSelected(
            customOwner,
            "main",
            _assetManagers(customAssetManager),
            vaultAssets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols
        );

        BittyVault customVault = BittyVault(payable(vaultAddr));
        assertTrue(customVault.hasRole(customVault.DEFAULT_ADMIN_ROLE(), customOwner));
        assertTrue(customVault.hasRole(customVault.ASSET_MANAGER_ROLE(), customAssetManager));
        assertEq(factory.computeVaultAddress(customOwner, "main"), vaultAddr);
    }
}
