// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {AmountIsZero, AddressZero} from "../../src/interfaces/IBittyV1Vault.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {
    InvalidLendingProtocol,
    InvalidStakingProtocol,
    InvalidAMMProtocol,
    RebalanceDisabled,
    MinimalBalanceNotMet,
    DisableRebalanceUntilTimestampTooEarly,
    ETHBalanceNotEnough
} from "../../src/interfaces/IBittyV1AssetManager.sol";
import {Deprecated, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1LendingProtocol} from "protocol-contracts/src/interfaces/IBittyV1LendingProtocol.sol";
import {IBittyV1StakingProtocol} from "protocol-contracts/src/interfaces/IBittyV1StakingProtocol.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {mainnet} from "protocol-contracts/script/addresses.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {AddingAssetsDisabled} from "../../src/interfaces/IBittyV1Vault.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {ProtocolTestSetup} from "../helpers/ProtocolTestSetup.sol";
import {MockAMMProtocol} from "../helpers/MockAMMProtocol.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";

contract TestAssetManager is ProtocolTestSetup, BittyV1Vault {
    using Clones for address;

    address public guardAddress;
    address[] public assets;
    address[] public vaultAssets;
    address[] public lendingProtocols;
    address[] public stakingProtocols;
    address[] public ammProtocols;
    address[] public intentProtocols;
    address public ownerAddress;
    address public assetManagerAddress;

    function setUp() public {
        ownerAddress = tx.origin;
        assetManagerAddress = address(this);

        BittyV1Guard guard = new BittyV1Guard();
        guardAddress = address(guard);

        vm.startPrank(tx.origin);
        guard.grantRole(guard.ASSET_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.STABLE_COIN_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.LENDING_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.STAKING_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.AMM_MANAGER_ROLE(), tx.origin);
        guard.addAssets(_two(mainnet.WETH, WBTC));
        guard.addStableCoins(_two(mainnet.USDT, mainnet.USDC));
        vm.stopPrank();

        setupMainnetForkProtocols(guard);

        assets = _two(mainnet.WETH, WBTC);
        vaultAssets = new address[](4);
        vaultAssets[0] = mainnet.WETH;
        vaultAssets[1] = WBTC;
        vaultAssets[2] = mainnet.USDT;
        vaultAssets[3] = mainnet.USDC;
        lendingProtocols = _single(address(aaveProtocol));
        stakingProtocols = _single(address(lidoProtocol));
        ammProtocols = _single(address(uniswapV3Protocol));
        intentProtocols = new address[](0);
    }

    function _two(address a, address b) private pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _assetManagers(address manager) internal pure returns (address[] memory managers) {
        managers = new address[](1);
        managers[0] = manager;
    }

    function getClonedProvider(address protocol) external view returns (address) {
        return _assetManager.clonedProtocols[protocol];
    }

    function _cloneProtocolForTest(address protocol) private returns (address clonedProtocol) {
        clonedProtocol = _assetManager.clonedProtocols[protocol];
        if (clonedProtocol != address(0)) {
            return clonedProtocol;
        }
        clonedProtocol = protocol.clone();
        IBittyV1Protocol(clonedProtocol).initialize(address(this));
        _assetManager.clonedProtocols[protocol] = clonedProtocol;
    }

    function _initializeWithMockAMM(MockAMMProtocol mockAmm) internal {
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).addAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        this.initialize(
            ownerAddress,
            "test",
            _assetManagers(assetManagerAddress),
            guardAddress,
            mainnet.WETH,
            vaultAssets,
            lendingProtocols,
            stakingProtocols,
            _single(address(mockAmm)),
            intentProtocols
        );
        _cloneProtocolForTest(address(mockAmm));
    }

    function _deprecateVaultAMMProtocols() internal {
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).deprecateAMMProtocols(ammProtocols);
    }

    function _roleError(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    function doInitialize() public {
        this.initialize(
            ownerAddress,
            "test",
            _assetManagers(assetManagerAddress),
            guardAddress,
            mainnet.WETH,
            vaultAssets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );
    }

    function test_SetMinimalBalance() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, 100 * 1e6);
    }

    function test_RevertOnlyAssetManager() public {
        this.doInitialize();
        address stranger = makeAddr("subscribedStranger");
        bytes32 role = ASSET_MANAGER_ROLE;

        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, role));
        this.supply(address(aaveProtocol), address(mainnet.WETH), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, role));
        this.withdraw(address(aaveProtocol), address(mainnet.WETH), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, role));
        this.marketSell(address(uniswapV3Protocol), address(WBTC), address(mainnet.USDT), 1 ether, 1 ether, "");
    }

    function test_SupplyRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), address(0), 1 ether);
    }

    function test_SupplyRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), address(mainnet.WETH), 0);
    }

    function test_WithdrawRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), address(mainnet.WETH), 0);
    }

    function test_WithdrawRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), address(0), 1 ether);
    }

    function test_revertETHToWETH() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, ASSET_MANAGER_ROLE));
        this.ETHToWETH(1 ether);
    }

    function test_ETHToWETHSuccess() public {
        this.doInitialize();
        uint256 wethBefore = IERC20(mainnet.WETH).balanceOf(address(this));
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);
        vm.prank(assetManagerAddress);
        this.ETHToWETH(amount);
        assertApproxEqAbs(IERC20(mainnet.WETH).balanceOf(address(this)) - wethBefore, amount, 10);
    }

    /// @dev Regression: plain ETH sends must not revert (BittyV1Vault.receive). Matches wallet "Send ETH" (empty calldata).
    function test_ethDeposit_viaReceive_thenETHToWETH() public {
        this.doInitialize();

        uint256 amount = 0.1 ether;
        address depositor = makeAddr("ethDepositor");
        uint256 ethBefore = address(this).balance;
        uint256 wethBefore = IERC20(mainnet.WETH).balanceOf(address(this));

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success, bytes memory returnData) = address(this).call{value: amount}("");

        assertTrue(success, string(returnData));
        assertEq(address(this).balance - ethBefore, amount);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), wethBefore);

        uint256 ethAfterDeposit = address(this).balance;
        vm.prank(assetManagerAddress);
        this.ETHToWETH(amount);

        assertEq(address(this).balance, ethAfterDeposit - amount);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), wethBefore + amount);
    }

    function test_ETHToWETH_revertsWhenEthBalanceInsufficient() public {
        this.doInitialize();

        vm.deal(address(this), 0.5 ether);

        vm.prank(assetManagerAddress);
        vm.expectRevert(ETHBalanceNotEnough.selector);
        this.ETHToWETH(1 ether);
    }

    function test_SupplyRevertInvalidLendingProtocol() public {
        this.doInitialize();
        address invalidLendingProtocol = address(new AaveV3Protocol(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER));
        vm.expectRevert(InvalidLendingProtocol.selector);
        vm.prank(assetManagerAddress);
        this.supply(invalidLendingProtocol, address(mainnet.WETH), 1 ether);
    }

    function test_SupplySuccess() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        require(clonedProtocol != address(0), "Provider should be cloned");

        uint256 balanceAfter = IBittyV1LendingProtocol(clonedProtocol).getSuppliedBalance(mainnet.WETH);
        assertApproxEqAbs(balanceAfter, supplyAmount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_WithdrawSuccess() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        uint256 withdrawAmount = 0.5 ether;

        deal(mainnet.WETH, address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        uint256 balanceBefore = IERC20(mainnet.WETH).balanceOf(address(this));

        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), mainnet.WETH, withdrawAmount);

        uint256 balanceAfter = IERC20(mainnet.WETH).balanceOf(address(this));
        assertApproxEqAbs(balanceAfter - balanceBefore, withdrawAmount, 5);

        uint256 remaining = IBittyV1LendingProtocol(clonedProtocol).getSuppliedBalance(mainnet.WETH);
        assertApproxEqAbs(remaining, supplyAmount - withdrawAmount, 10);
    }

    function test_LendingProviderRevertIfNotRegistered() public {
        this.doInitialize();

        address invalidLendingProtocol = makeAddr("InvalidLendingProtocol");
        vm.expectRevert(InvalidLendingProtocol.selector);
        vm.prank(assetManagerAddress);
        this.supply(invalidLendingProtocol, address(mainnet.WETH), 1 ether);
    }

    function test_SupplyFromDeprecatedLendingProvider() public {
        this.doInitialize();
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).deprecateLendingProtocols(lendingProtocols);
        vm.expectRevert(Deprecated.selector);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), address(mainnet.WETH), 1 ether);
    }

    function test_WithdrawMoneySuccessFromDeprecateLendingProvider() public {
        this.doInitialize();
        deal(address(mainnet.WETH), address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), address(mainnet.WETH), 1 ether);
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).deprecateLendingProtocols(lendingProtocols);
        uint256 supplied = this.getSuppliedBalance(address(aaveProtocol), address(mainnet.WETH));
        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), address(mainnet.WETH), supplied);
    }

    function test_WithdrawFromInvalidLendingProtocol() public {
        this.doInitialize();
        address invalidLendingProtocol = makeAddr("InvalidLendingProtocol");
        vm.expectRevert(InvalidLendingProtocol.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(invalidLendingProtocol, address(mainnet.WETH), 1 ether);
    }

    function test_GetBalance() public {
        this.doInitialize();
        uint256 depositAmount = 5 ether;

        uint256 balance = this.getSuppliedBalance(address(aaveProtocol), address(mainnet.WETH));
        assertEq(balance, 0);

        deal(address(mainnet.WETH), address(this), depositAmount);
        IERC20(mainnet.WETH).approve(address(this), depositAmount);

        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), address(mainnet.WETH), depositAmount);

        balance = this.getSuppliedBalance(address(aaveProtocol), address(mainnet.WETH));
        assertApproxEqAbs(balance, depositAmount, 10);
    }

    function test_GetBalance_InvalidLendingProtocol() public {
        this.doInitialize();
        address invalidLendingProtocol = makeAddr("InvalidLendingProtocol");

        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidLendingProtocol.selector);
        this.getSuppliedBalance(invalidLendingProtocol, address(mainnet.WETH));
    }

    function test_GetBalanceFromDeprecatedLendingProvider() public {
        this.doInitialize();
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).deprecateLendingProtocols(lendingProtocols);
        uint256 balance = this.getSuppliedBalance(address(aaveProtocol), address(mainnet.WETH));
        assertEq(balance, 0);
    }

    function test_RebalanceFromCheck_RevertsWhenFromNotVaultAsset() public {
        this.doInitialize();

        address invalidFrom = makeAddr("invalidFromAsset");
        uint256 sellAmount = 1 ether;
        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(invalidFrom, sellAmount, address(mainnet.USDT), buyAmount);

        vm.expectRevert(NotRegistered.selector);
        vm.prank(assetManagerAddress);
        this.marketSell(address(uniswapV3Protocol), invalidFrom, address(mainnet.USDT), sellAmount, buyAmount, swapData);
    }

    function test_RebalanceFromCheck_MinimalBalanceNotMet_WhenRemainingBelowMinimal() public {
        this.doInitialize();

        uint256 minimalBalance = 100 ether;
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, minimalBalance);

        uint256 fromBalance = 1000 ether;
        uint256 sellAmount = 950 ether;

        deal(address(mainnet.WETH), address(this), fromBalance);
        IERC20(mainnet.WETH).approve(address(this), fromBalance);

        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mainnet.WETH), sellAmount, address(mainnet.USDT), buyAmount);

        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManagerAddress);
        this.marketSell(
            address(uniswapV3Protocol), address(mainnet.WETH), address(mainnet.USDT), sellAmount, buyAmount, swapData
        );
    }

    function test_RebalanceFromCheck_MinimalBalanceNotMet_WhenSellExceedsBalance() public {
        this.doInitialize();

        uint256 minimalBalance = 100 ether;
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, minimalBalance);

        uint256 fromBalance = 50 ether;
        uint256 sellAmount = 100 ether;

        deal(address(mainnet.WETH), address(this), fromBalance);
        IERC20(mainnet.WETH).approve(address(this), fromBalance);

        uint256 buyAmount = 10 * 1e6;
        bytes memory swapData = abi.encode(address(mainnet.WETH), sellAmount, address(mainnet.USDT), buyAmount);

        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManagerAddress);
        this.marketSell(
            address(uniswapV3Protocol), address(mainnet.WETH), address(mainnet.USDT), sellAmount, buyAmount, swapData
        );
    }

    function test_RebalanceFromCheck_MinimalBalance_SucceedsWhenRemainingAtLeastMinimal() public {
        this.doInitialize();

        uint256 minimalBalance = 4 ether;
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, minimalBalance);

        uint256 fromBalance = 10 ether;
        uint256 sellAmount = 5 ether;

        deal(mainnet.WETH, address(this), fromBalance);
        uint256 buyAmountMin = 1;
        bytes memory swapData = encodeWethToUsdtSwap(sellAmount, buyAmountMin);

        vm.prank(assetManagerAddress);
        this.marketSell(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);

        assertApproxEqAbs(IERC20(mainnet.WETH).balanceOf(address(this)), fromBalance - sellAmount, 10);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_RevertsWhenBeforeTimestamp() public {
        this.doInitialize();

        uint256 disabledUntil = block.timestamp + 100;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(disabledUntil);

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), sellAmount);
        uint256 buyAmountMin = 1;
        bytes memory swapData = encodeWethToUsdtSwap(sellAmount, buyAmountMin);

        vm.expectRevert(RebalanceDisabled.selector);
        vm.prank(assetManagerAddress);
        this.marketSell(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_SucceedsAfterTimestamp() public {
        this.doInitialize();

        uint256 disabledUntil = block.timestamp + 100;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(disabledUntil);

        vm.warp(disabledUntil + 1);

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), sellAmount);
        uint256 buyAmountMin = 1;
        bytes memory swapData = encodeWethToUsdtSwap(sellAmount, buyAmountMin);

        vm.prank(assetManagerAddress);
        this.marketSell(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);

        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_CheckRebalanceDisabledUntilTimestamp_SucceedsWhenNeverDisabled() public {
        this.doInitialize();

        uint256 sellAmount = 0.01 ether;
        deal(mainnet.WETH, address(this), sellAmount);
        uint256 buyAmountMin = 1;
        bytes memory swapData = encodeWethToUsdtSwap(sellAmount, buyAmountMin);

        vm.prank(assetManagerAddress);
        this.marketSell(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, sellAmount, buyAmountMin, swapData);

        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_DisableRebalanceUntilTimestampTooEarly_RevertsWhenNewTimestampEarlier() public {
        this.doInitialize();

        uint256 firstDisabledUntil = block.timestamp + 200;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(firstDisabledUntil);

        uint256 earlierTimestamp = block.timestamp + 100;
        vm.expectRevert(DisableRebalanceUntilTimestampTooEarly.selector);
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(earlierTimestamp);
    }

    function test_DisableAddingAssets_RevertsWhenNotOwnerOrAssetManager() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, DEFAULT_ADMIN_ROLE));
        this.disableAddingAssets();
    }

    function test_AddAssets_afterInit_addsStableCoinViaUnifiedPath() public {
        this.initialize(
            ownerAddress,
            "test",
            _assetManagers(assetManagerAddress),
            guardAddress,
            mainnet.WETH,
            assets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols
        );

        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(usdc);

        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addStableCoins(toAdd);

        vm.prank(ownerAddress);
        this.addAssets(toAdd);

        assertEq(this.getStableCoins().length, 1);
        assertEq(this.getStableCoins()[0], address(usdc));
        assertEq(this.getAssets().length, 2);
    }

    function test_DisableAddingAssets_SucceedsAndAddAssetsReverts() public {
        this.doInitialize();

        MockERC20 mockDAI = new MockERC20("DAI", "DAI", 18);
        address[] memory newAssets = new address[](1);
        newAssets[0] = address(mockDAI);
        vm.prank(ownerAddress);
        BittyV1Guard(guardAddress).addAssets(newAssets);

        vm.prank(ownerAddress);
        this.disableAddingAssets();

        vm.expectRevert(AddingAssetsDisabled.selector);
        vm.prank(ownerAddress);
        this.addAssets(newAssets);
    }

    function test_StakeRevertOnlyAssetManager() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        address stranger = makeAddr("subscribedStranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, ASSET_MANAGER_ROLE));
        this.stake(address(lidoProtocol), mainnet.WETH, 1 ether);
    }

    function test_StakeRevertInvalidStakingProtocol() public {
        this.doInitialize();
        address invalidStakingProvider = makeAddr("InvalidStakingProtocol");
        vm.expectRevert(InvalidStakingProtocol.selector);
        vm.prank(assetManagerAddress);
        this.stake(invalidStakingProvider, mainnet.WETH, 1 ether);
    }

    function test_StakeRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, 0);
    }

    function test_StakeSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        assertEq(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), 0);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        address clonedProtocol = this.getClonedProvider(address(lidoProtocol));
        assertTrue(clonedProtocol != address(0));
        assertApproxEqAbs(IBittyV1StakingProtocol(clonedProtocol).getStakedBalance(mainnet.WETH), stakeAmount, 10);
        assertApproxEqAbs(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), stakeAmount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_GetStakingBalance() public {
        this.doInitialize();
        assertEq(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), 0);

        uint256 stakeAmount = 2 ether;
        deal(mainnet.WETH, address(this), stakeAmount);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        assertApproxEqAbs(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), stakeAmount, 10);
    }

    function test_GetStakingBalance_InvalidStakingProtocol() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProtocol.selector);
        this.getStakedBalance(makeAddr("InvalidStakingProtocol"), mainnet.WETH);
    }

    function test_UnstakeSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 1 ether;
        uint256 unstakeAmount = 0.5 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);
        assertApproxEqAbs(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), stakeAmount, 10);

        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProtocol), mainnet.WETH, unstakeAmount);
        assertApproxEqAbs(this.getStakedBalance(address(lidoProtocol), mainnet.WETH), stakeAmount - unstakeAmount, 10);

        uint256[] memory requestIds = this.getUnstakeRequestIds(address(lidoProtocol));
        assertEq(requestIds.length, 1);

        vm.prank(assetManagerAddress);
        this.claimUnstaked(address(lidoProtocol), requestIds);
    }

    function test_ClaimSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 0.1 ether;
        uint256 unstakeAmount = 0.05 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);
        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProtocol), mainnet.WETH, unstakeAmount);

        uint256[] memory requestIds = this.getUnstakeRequestIds(address(lidoProtocol));
        assertEq(requestIds.length, 1);

        vm.prank(assetManagerAddress);
        this.claimUnstaked(address(lidoProtocol), requestIds);
        // Lido withdrawals are not finalized immediately on a mainnet fork.
        assertEq(this.getUnstakeRequestIds(address(lidoProtocol)).length, 1);
    }

    function test_ClaimRevertOnlyAssetManager() public {
        this.doInitialize();
        uint256[] memory requestIds = new uint256[](0);
        address stranger = makeAddr("subscribedStranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, ASSET_MANAGER_ROLE));
        this.claimUnstaked(address(lidoProtocol), requestIds);
    }

    function test_ClaimRevertInvalidStakingProtocol() public {
        this.doInitialize();
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = 1;
        vm.expectRevert(InvalidStakingProtocol.selector);
        vm.prank(assetManagerAddress);
        this.claimUnstaked(makeAddr("InvalidStakingProtocol"), requestIds);
    }

    function test_ClaimEmptyRequestIds_doesNotRevert() public {
        this.doInitialize();
        uint256[] memory requestIds = new uint256[](0);
        vm.prank(assetManagerAddress);
        this.claimUnstaked(address(lidoProtocol), requestIds);
    }

    function test_UnstakeRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProtocol), mainnet.WETH, 0);
    }

    function test_UnstakeRevertInvalidStakingProtocol() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProtocol.selector);
        vm.prank(assetManagerAddress);
        this.unstake(makeAddr("InvalidStakingProtocol"), mainnet.WETH, 1 ether);
    }

    function test_GetUnstakeRequestIds() public {
        this.doInitialize();
        uint256[] memory ids = this.getUnstakeRequestIds(address(lidoProtocol));
        assertEq(ids.length, 0);

        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, 1 ether);
        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProtocol), mainnet.WETH, 0.5 ether);

        ids = this.getUnstakeRequestIds(address(lidoProtocol));
        assertEq(ids.length, 1);
    }

    function test_GetUnstakeRequestIds_InvalidStakingProtocol() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProtocol.selector);
        this.getUnstakeRequestIds(makeAddr("InvalidStakingProtocol"));
    }

    function test_SupplyAllowanceIsZeroAfterSuccess() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount);

        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        assertEq(IERC20(mainnet.WETH).allowance(address(this), clonedProtocol), 0, "Allowance should be 0 after supply");
    }

    function test_SupplySucceedsWithPreExistingResidualAllowance() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount);

        address clonedProtocol = _cloneProtocolForTest(address(aaveProtocol));

        IERC20(mainnet.WETH).approve(clonedProtocol, 1);
        assertEq(IERC20(mainnet.WETH).allowance(address(this), clonedProtocol), 1);

        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);

        assertApproxEqAbs(IBittyV1LendingProtocol(clonedProtocol).getSuppliedBalance(mainnet.WETH), supplyAmount, 10);
    }

    // ─── AMM: deprecated protocol and decreaseLiquidity ───────────────────────

    function test_MarketSellRevertDeprecatedAMMProtocol() public {
        this.doInitialize();
        _deprecateVaultAMMProtocols();
        vm.expectRevert(Deprecated.selector);
        vm.prank(assetManagerAddress);
        this.marketSell(
            address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, 1 ether, 1, encodeWethToUsdtSwap(1 ether, 1)
        );
    }

    function test_MarketBuyRevertDeprecatedAMMProtocol() public {
        this.doInitialize();
        _deprecateVaultAMMProtocols();
        vm.expectRevert(Deprecated.selector);
        vm.prank(assetManagerAddress);
        this.marketBuy(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, 1, 1 ether, "");
    }

    function test_AddLiquidityRevertDeprecatedAMMProtocol() public {
        this.doInitialize();
        _deprecateVaultAMMProtocols();
        vm.expectRevert(Deprecated.selector);
        vm.prank(assetManagerAddress);
        this.addLiquidity(address(uniswapV3Protocol), mainnet.WETH, 0, mainnet.USDT, 0, "");
    }

    function test_DecreaseLiquiditySuccess() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address clone = this.getClonedProvider(address(mockAmm));
        bytes memory data = abi.encode(uint256(1));

        vm.prank(assetManagerAddress);
        this.decreaseLiquidity(address(mockAmm), data);

        assertEq(MockAMMProtocol(clone).decreaseLiquidityCallCount(), 1);
        assertEq(MockAMMProtocol(clone).lastDecreaseData(), data);
    }

    function test_DecreaseLiquiditySuccessOnDeprecatedAMMProtocol() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address clone = this.getClonedProvider(address(mockAmm));
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).deprecateAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        bytes memory data = abi.encode(uint256(42));
        vm.prank(assetManagerAddress);
        this.decreaseLiquidity(address(mockAmm), data);

        assertEq(MockAMMProtocol(clone).decreaseLiquidityCallCount(), 1);
        assertEq(MockAMMProtocol(clone).lastDecreaseData(), data);
    }

    function test_RemoveLiquiditySuccessOnDeprecatedAMMProtocol() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address clone = this.getClonedProvider(address(mockAmm));
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).deprecateAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        bytes memory data = abi.encode(uint256(7));
        vm.prank(assetManagerAddress);
        this.removeLiquidity(address(mockAmm), data);

        assertEq(MockAMMProtocol(clone).removeLiquidityCallCount(), 1);
        assertEq(MockAMMProtocol(clone).lastRemoveData(), data);
    }

    function test_DecreaseLiquidityRevertInvalidAMMProtocolWhenNotCloned() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).addAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        this.initialize(
            ownerAddress,
            "test",
            _assetManagers(assetManagerAddress),
            guardAddress,
            mainnet.WETH,
            vaultAssets,
            lendingProtocols,
            stakingProtocols,
            _single(address(mockAmm)),
            intentProtocols
        );

        vm.expectRevert(InvalidAMMProtocol.selector);
        vm.prank(assetManagerAddress);
        this.decreaseLiquidity(address(mockAmm), "");
    }

    function test_DecreaseLiquidityRevertOnlyAssetManager() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, ASSET_MANAGER_ROLE));
        this.decreaseLiquidity(address(mockAmm), "");
    }

    function test_GetLiquidityFromDeprecatedAMMProtocol() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).deprecateAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        assertEq(this.getLiquidity(address(mockAmm), ""), 0);
    }

    // ─── Fuzz Tests ───────────────────────────────────────────────────────────

    function testFuzz_SetMinimalBalance_anyValueAccepted(uint256 minimalBalance) public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, minimalBalance);
    }

    function testFuzz_RebalanceMinimalBalance_revertsWhenRemainingBelowMin(
        uint256 minimalBalance,
        uint256 fromBalance,
        uint256 sellAmount
    ) public {
        minimalBalance = bound(minimalBalance, 1 ether, 100 ether);
        fromBalance = bound(fromBalance, minimalBalance, minimalBalance + 100 ether);
        sellAmount = bound(sellAmount, fromBalance - minimalBalance + 1, fromBalance);
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setMinimalBalance(mainnet.WETH, minimalBalance);
        deal(mainnet.WETH, address(this), fromBalance);
        bytes memory swapData = abi.encode(mainnet.WETH, sellAmount, mainnet.USDT, uint256(1));
        vm.expectRevert(MinimalBalanceNotMet.selector);
        vm.prank(assetManagerAddress);
        this.marketSell(address(uniswapV3Protocol), mainnet.WETH, mainnet.USDT, sellAmount, 1, swapData);
    }

    function testFuzz_DisableRebalanceUntilTimestamp_cannotMovePrevTimestampEarlier(uint256 offset, uint256 reduction)
        public
    {
        offset = bound(offset, 1, type(uint64).max);
        reduction = bound(reduction, 1, offset);
        this.doInitialize();
        uint256 first = block.timestamp + offset;
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(first);
        vm.expectRevert(DisableRebalanceUntilTimestampTooEarly.selector);
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(first - reduction);
    }

    function test_StakeSucceedsWithPreExistingResidualAllowance() public {
        this.doInitialize();

        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        address clonedProtocol = _cloneProtocolForTest(address(lidoProtocol));

        IERC20(mainnet.WETH).approve(clonedProtocol, 1);
        assertEq(IERC20(mainnet.WETH).allowance(address(this), clonedProtocol), 1);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        assertApproxEqAbs(IBittyV1StakingProtocol(clonedProtocol).getStakedBalance(mainnet.WETH), stakeAmount, 10);
    }
}
