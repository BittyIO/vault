// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {IVaultFull} from "../helpers/IVaultFull.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {VaultAlreadyActivated} from "../../src/interfaces/IBittyV1VaultFactory.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";
import {LidoV2Protocol} from "protocol-contracts/src/protocols/LidoV2Protocol.sol";
import {mainnet} from "protocol-contracts/script/addresses.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IBittyV1Vault, RiskControlLevel} from "../../src/interfaces/IBittyV1Vault.sol";
import {UniswapV3Protocol} from "protocol-contracts/src/protocols/UniswapV3Protocol.sol";
import {Path} from "protocol-contracts/src/libs/uniswap/v3/Uniswap.sol";

/// @notice Mainnet fork integration tests for BittyV1Vault with real Aave and Lido providers.
contract TestVaultFork is Test {
    using SafeERC20 for IERC20;
    using Path for bytes;

    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    BittyV1Vault public vaultImpl;
    BittyV1Vault public vault;
    BittyV1VaultFactory public factory;
    BittyV1Guard public guard;
    AaveV3Protocol public aaveProtocol;
    LidoV2Protocol public lidoProtocol;
    UniswapV3Protocol public uniswapV3Protocol;
    address public assetManager;

    address[] public assets;
    address[] public vaultAssets;
    address[] public lendingProtocols;
    address[] public stakingProtocols;
    address[] public ammProtocols;
    address[] public intentProtocols;

    function setUp() public {
        vm.createSelectFork("mainnet");

        guard = new BittyV1Guard();
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
        intentProtocols = new address[](0);

        vaultImpl = new BittyV1Vault();
        BittyV1VaultDeFiFacet defiFacet = new BittyV1VaultDeFiFacet();
        factory = new BittyV1VaultFactory();
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(address(vaultImpl), address(defiFacet), address(guard), mainnet.WETH);

        assetManager = address(this);
        vm.startPrank(tx.origin);
        factory.activateVault(
            RiskControlLevel.Zero, vaultAssets, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols
        );
        address vaultAddr = factory.vaultAddress(tx.origin);
        BittyV1Vault(payable(vaultAddr)).setManager(assetManager, 0, 0, type(uint64).max, 0);
        vm.stopPrank();
        vault = BittyV1Vault(payable(vaultAddr));
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
        assertEq(IVaultFull(payable(address(vault))).wethAddress(), mainnet.WETH);

        address[] memory lending = IVaultFull(payable(address(vault))).getLendingProtocols();
        assertEq(lending.length, 1);
        assertEq(lending[0], address(aaveProtocol));

        address[] memory staking = IVaultFull(payable(address(vault))).getStakingProtocols();
        assertEq(staking.length, 1);
        assertEq(staking[0], address(lidoProtocol));
    }

    function test_SupplyToAave() public {
        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(vault), amount);

        uint256 balanceBefore =
            IVaultFull(payable(address(vault))).getSuppliedBalance(address(aaveProtocol), mainnet.WETH);
        assertEq(balanceBefore, 0);

        IVaultFull(payable(address(vault))).supply(address(aaveProtocol), mainnet.WETH, amount);

        uint256 balanceAfter =
            IVaultFull(payable(address(vault))).getSuppliedBalance(address(aaveProtocol), mainnet.WETH);
        assertApproxEqAbs(balanceAfter, amount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);
    }

    function test_WithdrawFromAave() public {
        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(vault), supplyAmount);
        IVaultFull(payable(address(vault))).supply(address(aaveProtocol), mainnet.WETH, supplyAmount);

        uint256 withdrawAmount = 0.5 ether;
        uint256 vaultBalanceBefore = IERC20(mainnet.WETH).balanceOf(address(vault));

        IVaultFull(payable(address(vault))).withdraw(address(aaveProtocol), mainnet.WETH, withdrawAmount);

        uint256 vaultBalanceAfter = IERC20(mainnet.WETH).balanceOf(address(vault));
        assertApproxEqAbs(vaultBalanceAfter - vaultBalanceBefore, withdrawAmount, 5);

        uint256 remaining = IVaultFull(payable(address(vault))).getSuppliedBalance(address(aaveProtocol), mainnet.WETH);
        assertApproxEqAbs(remaining, supplyAmount - withdrawAmount, 10);
    }

    function test_StakeToLido() public {
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(vault), stakeAmount);

        uint256 stakingBalanceBefore =
            IVaultFull(payable(address(vault))).getStakedBalance(address(lidoProtocol), mainnet.WETH);

        IVaultFull(payable(address(vault))).stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        uint256 stakingBalanceAfter =
            IVaultFull(payable(address(vault))).getStakedBalance(address(lidoProtocol), mainnet.WETH);
        assertGt(stakingBalanceAfter, stakingBalanceBefore);
        assertApproxEqAbs(stakingBalanceAfter - stakingBalanceBefore, stakeAmount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);
    }

    function test_UnstakeFromLido() public {
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(vault), stakeAmount);
        IVaultFull(payable(address(vault))).stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        uint256 unstakeAmount = 0.05 ether;
        IVaultFull(payable(address(vault))).unstake(address(lidoProtocol), mainnet.WETH, unstakeAmount);

        uint256[] memory ids = IVaultFull(payable(address(vault))).getUnstakeRequestIds(address(lidoProtocol));
        assertEq(ids.length, 1);
    }

    function test_ClaimFromLido() public {
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(vault), stakeAmount);
        IVaultFull(payable(address(vault))).stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        uint256 unstakeAmount = 0.05 ether;
        IVaultFull(payable(address(vault))).unstake(address(lidoProtocol), mainnet.WETH, unstakeAmount);

        uint256[] memory ids = IVaultFull(payable(address(vault))).getUnstakeRequestIds(address(lidoProtocol));
        assertEq(ids.length, 1);

        IVaultFull(payable(address(vault))).claimUnstaked(address(lidoProtocol), ids);
        // On mainnet fork, Lido withdrawals are not finalized immediately, so request ids remain
        uint256[] memory remaining = IVaultFull(payable(address(vault))).getUnstakeRequestIds(address(lidoProtocol));
        assertEq(remaining.length, 1);
    }

    function test_SupplyAndWithdrawFullCycle() public {
        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(vault), amount);

        IVaultFull(payable(address(vault))).supply(address(aaveProtocol), mainnet.WETH, amount);

        uint256 lendingBalance =
            IVaultFull(payable(address(vault))).getSuppliedBalance(address(aaveProtocol), mainnet.WETH);
        IVaultFull(payable(address(vault))).withdraw(address(aaveProtocol), mainnet.WETH, lendingBalance);

        assertApproxEqAbs(IERC20(mainnet.WETH).balanceOf(address(vault)), amount, 5);
        assertEq(IVaultFull(payable(address(vault))).getSuppliedBalance(address(aaveProtocol), mainnet.WETH), 0);
    }

    /// @dev A plain ETH send (empty calldata, matching a wallet "Send ETH") is auto-wrapped to WETH
    ///      by BittyV1Vault.receive(), leaving the vault holding WETH and no native ETH.
    function test_Receive_autoWrapsPlainEthTransferToWETH() public {
        uint256 amount = 0.1 ether;
        address depositor = makeAddr("ethDepositor");
        uint256 wethBefore = IERC20(mainnet.WETH).balanceOf(address(vault));

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success, bytes memory returnData) = address(vault).call{value: amount}("");

        assertTrue(success, string(returnData));
        assertEq(address(vault).balance, 0);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)) - wethBefore, amount);
    }

    function test_RevertSupplyWhenNotManager() public {
        deal(mainnet.WETH, address(vault), 1 ether);
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        IVaultFull(payable(address(vault))).supply(address(aaveProtocol), mainnet.WETH, 1 ether);
    }

    function test_FactoryVaultAddress() public view {
        address computed = factory.vaultAddress(tx.origin);
        assertEq(computed, address(vault));
    }

    function test_FactoryRevertWhenVaultAlreadyActivated() public {
        vm.expectRevert(VaultAlreadyActivated.selector);
        vm.prank(tx.origin);
        factory.activateVault(
            RiskControlLevel.Zero, vaultAssets, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols
        );
    }

    function test_RebalanceWETHToUSDT() public {
        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(vault), sellAmount);

        address[] memory path = new address[](2);
        path[0] = mainnet.WETH;
        path[1] = mainnet.USDT;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        bytes memory encodedPath = Path.encodePath(path, fees);

        uint256 buyAmountMin = 1;
        bytes memory swapData = abi.encode(mainnet.WETH, sellAmount, mainnet.USDT, buyAmountMin, encodedPath);

        uint256 usdtBefore = IERC20(mainnet.USDT).balanceOf(address(vault));
        IVaultFull(payable(address(vault)))
            .marketSell(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);
        uint256 usdtAfter = IERC20(mainnet.USDT).balanceOf(address(vault));
        assertGt(usdtAfter, usdtBefore);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);
    }

    function test_AddScheduledPaymentAndPayScheduledPayment() public {
        deal(mainnet.USDC, address(vault), 1000e6);

        IBittyV1Vault.ScheduledPayment memory scheduledPayment = IBittyV1Vault.ScheduledPayment({
            scheduledPaymentAddress: address(this),
            trigger: address(0),
            assetAddress: mainnet.USDC,
            amount: 100e6,
            remainingPaymentCount: 1,
            startTimestamp: block.timestamp,
            paymentInterval: 1 days,
            isImmutable: false,
            payWithInsufficientBalance: false
        });

        vm.prank(tx.origin);
        uint256 testId = vault.addScheduledPayment(scheduledPayment);

        vm.warp(block.timestamp + 8 days);

        uint256 balanceBefore = IERC20(mainnet.USDC).balanceOf(address(this));
        vault.payScheduled(testId);
        uint256 balanceAfter = IERC20(mainnet.USDC).balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, 100e6);
    }

    function test_AssetManagerWithdrawFromAaveAndPayScheduledPaymentInOneBlock() public {
        uint256 supplyAmount = 1 ether;
        uint256 payAmount = 0.5 ether;
        address scheduledPaymentAddr = makeAddr("scheduledPaymentBeneficiary");

        deal(mainnet.WETH, address(vault), supplyAmount);
        IVaultFull(payable(address(vault))).supply(address(aaveProtocol), mainnet.WETH, supplyAmount);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);

        IBittyV1Vault.ScheduledPayment memory scheduledPayment = IBittyV1Vault.ScheduledPayment({
            scheduledPaymentAddress: scheduledPaymentAddr,
            trigger: address(0),
            assetAddress: mainnet.WETH,
            amount: payAmount,
            remainingPaymentCount: 1,
            startTimestamp: block.timestamp,
            paymentInterval: 1 days,
            isImmutable: false,
            payWithInsufficientBalance: false
        });
        vm.prank(tx.origin);
        uint256 salaryId = vault.addScheduledPayment(scheduledPayment);
        vm.warp(block.timestamp + 1 days);

        uint256 scheduledPaymentBefore = IERC20(mainnet.WETH).balanceOf(scheduledPaymentAddr);

        IVaultFull(payable(address(vault))).withdraw(address(aaveProtocol), mainnet.WETH, payAmount);
        vault.payScheduled(salaryId);

        uint256 scheduledPaymentAfter = IERC20(mainnet.WETH).balanceOf(scheduledPaymentAddr);
        assertEq(scheduledPaymentAfter - scheduledPaymentBefore, payAmount);

        uint256 remaining = IVaultFull(payable(address(vault))).getSuppliedBalance(address(aaveProtocol), mainnet.WETH);
        assertGe(remaining, supplyAmount - payAmount);
    }

    function test_MultiStep_rebalanceThenPayScheduledPaymentThenRebalance() public {
        deal(mainnet.WETH, address(vault), 1 ether);

        address[] memory path = new address[](2);
        path[0] = mainnet.WETH;
        path[1] = mainnet.USDT;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        bytes memory encodedPath = Path.encodePath(path, fees);

        // Step 1: rebalance 0.3 WETH → USDT
        uint256 firstSell = 0.3 ether;
        IVaultFull(payable(address(vault)))
            .marketSell(
                address(uniswapV3Protocol),
                mainnet.WETH,
                mainnet.USDT,
                firstSell,
                1,
                abi.encode(mainnet.WETH, firstSell, mainnet.USDT, uint256(1), encodedPath)
            );
        assertGt(IERC20(mainnet.USDT).balanceOf(address(vault)), 0);
        assertApproxEqAbs(IERC20(mainnet.WETH).balanceOf(address(vault)), 0.7 ether, 10);

        // Step 2: add WETH scheduledPayment and pay
        address scheduledPaymentAddr = makeAddr("recipient");
        IBittyV1Vault.ScheduledPayment memory scheduledPayment = IBittyV1Vault.ScheduledPayment({
            scheduledPaymentAddress: scheduledPaymentAddr,
            trigger: address(0),
            assetAddress: mainnet.WETH,
            amount: 0.5 ether,
            remainingPaymentCount: 1,
            startTimestamp: block.timestamp,
            paymentInterval: 0,
            isImmutable: false,
            payWithInsufficientBalance: false
        });
        vm.prank(tx.origin);
        uint256 recipientId = vault.addScheduledPayment(scheduledPayment);
        vault.payScheduled(recipientId);
        assertEq(IERC20(mainnet.WETH).balanceOf(scheduledPaymentAddr), 0.5 ether);

        // Step 3: rebalance remaining WETH → USDT
        uint256 remainingWeth = IERC20(mainnet.WETH).balanceOf(address(vault));
        assertGt(remainingWeth, 0);
        uint256 usdtBefore = IERC20(mainnet.USDT).balanceOf(address(vault));
        IVaultFull(payable(address(vault)))
            .marketSell(
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

    function test_ActivateVault_customOwner() public {
        address customOwner = makeAddr("customVaultOwner");
        address customAssetManager = makeAddr("customAssetManager");
        vm.startPrank(customOwner);
        factory.activateVault(
            RiskControlLevel.Zero, vaultAssets, lendingProtocols, stakingProtocols, ammProtocols, intentProtocols
        );
        address vaultAddr = factory.vaultAddress(customOwner);
        BittyV1Vault(payable(vaultAddr)).setManager(customAssetManager, 0, 0, type(uint64).max, 0);
        vm.stopPrank();

        BittyV1Vault customVault = BittyV1Vault(payable(vaultAddr));
        assertTrue(customVault.hasRole(customVault.DEFAULT_ADMIN_ROLE(), customOwner));
        assertEq(customVault.getManager(), customAssetManager);
        assertEq(factory.vaultAddress(customOwner), vaultAddr);
    }
}
