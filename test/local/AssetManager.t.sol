// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AmountIsZero,
    AddressZero,
    NotInitialized,
    InsufficientBalance,
    ArrayLengthMismatch
} from "../../src/interfaces/IBittyV1Vault.sol";
import {RiskSettings, AutoYield} from "../../src/interfaces/IBittyV1Vault.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {
    InvalidLendingProtocol,
    InvalidStakingProtocol,
    InvalidAMMProtocol,
    InvalidIntentProtocol,
    RebalanceDisabled,
    MinimalBalanceNotMet,
    NotAssetManager,
    DisableRebalanceUntilTimestampTooEarly,
    DisableRebalanceUntilTimestampTooLong
} from "../../src/interfaces/IBittyV1AssetManager.sol";
import {Deprecated, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1LendingProtocol} from "protocol-contracts/src/interfaces/IBittyV1LendingProtocol.sol";
import {IBittyV1StakingProtocol} from "protocol-contracts/src/interfaces/IBittyV1StakingProtocol.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {mainnet} from "protocol-contracts/script/addresses.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {BittyV1VaultHarness} from "../helpers/BittyV1VaultHarness.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {AddingAssetsDisabled, AddingProtocolsDisabled} from "../../src/interfaces/IBittyV1Vault.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {ProtocolTestSetup} from "../helpers/ProtocolTestSetup.sol";
import {MockAMMProtocol} from "../helpers/MockAMMProtocol.sol";
import {MockIntentProtocol} from "../helpers/MockIntentProtocol.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";

contract TestAssetManager is ProtocolTestSetup, BittyV1VaultHarness {
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

    function _validTo() private view returns (uint32) {
        return uint32(block.timestamp + 1 days);
    }

    function _two(address a, address b) private pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _grantAssetManagerRole(address assetManager) internal {
        vm.prank(ownerAddress);
        this.setAssetManager(assetManager);
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
            guardAddress,
            mainnet.WETH,
            vaultAssets,
            lendingProtocols,
            stakingProtocols,
            _single(address(mockAmm)),
            intentProtocols,
            address(0),
            RiskSettings(0, 0, 0, 0),
            new AutoYield[](0),
            address(0)
        );
        _grantAssetManagerRole(assetManagerAddress);
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
            guardAddress,
            mainnet.WETH,
            vaultAssets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            address(0),
            RiskSettings(0, 0, 0, 0),
            new AutoYield[](0),
            address(0)
        );
        _grantAssetManagerRole(assetManagerAddress);
    }

    /// @dev Same vault, but with NO yield protocols enabled — the state a fresh
    ///      minimal activation leaves behind, which the simple* entry points
    ///      are built for.
    function doInitializeWithoutProtocols() public {
        this.initialize(
            ownerAddress,
            guardAddress,
            mainnet.WETH,
            vaultAssets,
            new address[](0),
            new address[](0),
            ammProtocols,
            intentProtocols,
            address(0),
            RiskSettings(0, 0, 0, 0),
            new AutoYield[](0),
            address(0)
        );
        _grantAssetManagerRole(assetManagerAddress);
    }

    function test_DisableAddingProtocols_BlocksAllProtocolTypesIncludingIntent() public {
        address intentProto = makeAddr("intentProtocol");
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addIntentProtocols(_single(intentProto));

        this.doInitialize();

        vm.startPrank(ownerAddress);
        this.disableAddingProtocols();
        assertTrue(this.isAddingProtocolsDisabled(), "adding protocols must be locked");

        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.updateLendingProtocols(_single(address(aaveProtocol)), new address[](0));

        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.updateStakingProtocols(_single(address(lidoProtocol)), new address[](0));

        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.updateAMMProtocols(_single(address(uniswapV3Protocol)), new address[](0));

        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.updateIntentProtocols(_single(intentProto), new address[](0));

        vm.stopPrank();
    }

    function test_DisableAddingProtocols_BlocksIntentEvenForRegisteredProtocol() public {
        address intentProto = makeAddr("intentProtocolOnly");
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addIntentProtocols(_single(intentProto));

        this.doInitialize();

        vm.prank(ownerAddress);
        this.updateIntentProtocols(_single(intentProto), new address[](0));

        vm.prank(ownerAddress);
        this.disableAddingProtocols();

        vm.prank(ownerAddress);
        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.updateIntentProtocols(_single(intentProto), new address[](0));
    }

    // One-element array builders so a single-asset setMinimalBalances call reads
    // cleanly and vm.prank(owner) lands on the external call itself.
    function _one(address a) private pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _one(uint256 v) private pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    function _bytesOne(bytes memory b) private pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = b;
    }

    function _getAutoYieldingOne(address asset) internal returns (address protocol, bool isSupplying) {
        (address[] memory protocols, bool[] memory isSupplyings) = this.getAutoYieldings(_one(asset));
        return (protocols[0], isSupplyings[0]);
    }

    function _route(address asset, address protocol, bool isSupplying) private pure returns (AutoYield[] memory arr) {
        arr = new AutoYield[](1);
        arr[0] = AutoYield({asset: asset, protocol: protocol, isSupplying: isSupplying});
    }

    function test_SetMinimalBalance() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setMinimalBalances(_one(mainnet.WETH), _one(uint256(100 * 1e6)));
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

    /**
     * @dev A plain ETH send (empty calldata, matching a wallet "Send ETH") is auto-wrapped to WETH
     *      by BittyV1Vault.receive(), leaving the vault holding WETH and no native ETH.
     */
    function test_ethDeposit_viaReceive_autoWrapsToWETH() public {
        this.doInitialize();

        uint256 amount = 0.1 ether;
        address depositor = makeAddr("ethDepositor");
        uint256 ethBefore = address(this).balance;
        uint256 wethBefore = IERC20(mainnet.WETH).balanceOf(address(this));

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success, bytes memory returnData) = address(this).call{value: amount}("");

        assertTrue(success, string(returnData));
        assertEq(address(this).balance, ethBefore);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)) - wethBefore, amount);
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
        uint256 supplied = this.getSuppliedBalances(_one(address(aaveProtocol)), _one(address(mainnet.WETH)))[0];
        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), address(mainnet.WETH), supplied);
    }

    function test_WithdrawWorksAfterLendingProtocolRemoved() public {
        this.doInitialize();
        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, amount);

        vm.prank(ownerAddress);
        this.updateLendingProtocols(new address[](0), _single(address(aaveProtocol)));

        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), mainnet.WETH, amount / 2);

        assertGt(IERC20(mainnet.WETH).balanceOf(address(this)), 0, "withdraw returned funds after removal");
    }

    function test_GetBalance() public {
        this.doInitialize();
        uint256 depositAmount = 5 ether;

        uint256 balance = this.getSuppliedBalances(_one(address(aaveProtocol)), _one(address(mainnet.WETH)))[0];
        assertEq(balance, 0);

        deal(address(mainnet.WETH), address(this), depositAmount);
        IERC20(mainnet.WETH).approve(address(this), depositAmount);

        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), address(mainnet.WETH), depositAmount);

        balance = this.getSuppliedBalances(_one(address(aaveProtocol)), _one(address(mainnet.WETH)))[0];
        assertApproxEqAbs(balance, depositAmount, 10);
    }

    function test_GetBalance_UnusedLendingProtocol_ReturnsZero() public {
        this.doInitialize();
        assertEq(this.getSuppliedBalances(_one(makeAddr("UnusedLendingProtocol")), _one(address(mainnet.WETH)))[0], 0);
    }

    function test_GetBalanceFromDeprecatedLendingProvider() public {
        this.doInitialize();
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).deprecateLendingProtocols(lendingProtocols);
        uint256 balance = this.getSuppliedBalances(_one(address(aaveProtocol)), _one(address(mainnet.WETH)))[0];
        assertEq(balance, 0);
    }

    function test_SetTradeLimit_RevertsForNonOwner() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, DEFAULT_ADMIN_ROLE));
        this.setAssetManager(assetManagerAddress);
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

    function test_DisableRebalanceUntilTimestamp_AllowsExactlyFourYears() public {
        this.doInitialize();

        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(block.timestamp + 4 * 365 days);
    }

    function test_DisableRebalanceUntilTimestamp_RevertsBeyondFourYears() public {
        this.doInitialize();

        vm.expectRevert(DisableRebalanceUntilTimestampTooLong.selector);
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(block.timestamp + 4 * 365 days + 1);
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
            guardAddress,
            mainnet.WETH,
            assets,
            lendingProtocols,
            stakingProtocols,
            ammProtocols,
            intentProtocols,
            address(0),
            RiskSettings(0, 0, 0, 0),
            new AutoYield[](0),
            address(0)
        );
        _grantAssetManagerRole(assetManagerAddress);

        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(usdc);

        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addStableCoins(toAdd);

        vm.prank(ownerAddress);
        this.updateAssets(toAdd, new address[](0));

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
        this.updateAssets(newAssets, new address[](0));
    }

    function test_StakeRevertOnlyAssetManager() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        address stranger = makeAddr("subscribedStranger");
        vm.prank(stranger);
        vm.expectRevert(NotAssetManager.selector);
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

        assertEq(this.getStakedBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 0);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        address clonedProtocol = this.getClonedProvider(address(lidoProtocol));
        assertTrue(clonedProtocol != address(0));
        assertApproxEqAbs(IBittyV1StakingProtocol(clonedProtocol).getStakedBalance(mainnet.WETH), stakeAmount, 10);
        assertApproxEqAbs(this.getStakedBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], stakeAmount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_GetStakingBalance() public {
        this.doInitialize();
        assertEq(this.getStakedBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 0);

        uint256 stakeAmount = 2 ether;
        deal(mainnet.WETH, address(this), stakeAmount);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);

        assertApproxEqAbs(this.getStakedBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], stakeAmount, 10);
    }

    function test_GetStakingBalance_UnusedStakingProtocol_ReturnsZero() public {
        this.doInitialize();
        assertEq(this.getStakedBalances(_one(makeAddr("UnusedStakingProtocol")), _one(mainnet.WETH))[0], 0);
    }

    function test_UnstakeSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 1 ether;
        uint256 unstakeAmount = 0.5 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, stakeAmount);
        assertApproxEqAbs(this.getStakedBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], stakeAmount, 10);

        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProtocol), mainnet.WETH, unstakeAmount);
        assertApproxEqAbs(
            this.getStakedBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], stakeAmount - unstakeAmount, 10
        );

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
        vm.expectRevert(NotAssetManager.selector);
        this.claimUnstaked(address(lidoProtocol), requestIds);
    }

    function test_RemoveLiquidityWorksAfterAMMProtocolRemoved() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);

        vm.prank(ownerAddress);
        this.updateAMMProtocols(new address[](0), _single(address(mockAmm)));

        bytes memory data = abi.encode(uint256(9));
        vm.prank(assetManagerAddress);
        this.removeLiquidity(address(mockAmm), data);

        address clone = this.getClonedProvider(address(mockAmm));
        assertEq(MockAMMProtocol(clone).removeLiquidityCallCount(), 1);
        assertEq(MockAMMProtocol(clone).lastRemoveData(), data);
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

    function test_UnstakeWorksAfterStakingProtocolRemoved() public {
        this.doInitialize();
        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, amount);

        vm.prank(ownerAddress);
        this.updateStakingProtocols(new address[](0), _single(address(lidoProtocol)));

        vm.prank(assetManagerAddress);
        this.unstake(address(lidoProtocol), mainnet.WETH, amount / 2);

        uint256[] memory ids =
            IBittyV1StakingProtocol(this.getClonedProvider(address(lidoProtocol))).getUnstakeRequestIds();
        assertEq(ids.length, 1, "unstake request created after removal");
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

    function test_GetUnstakeRequestIds_UnusedStakingProtocol_ReturnsEmpty() public {
        this.doInitialize();
        assertEq(this.getUnstakeRequestIds(makeAddr("UnusedStakingProtocol")).length, 0);
    }

    function test_SupplyAllowanceIsMaxAfterFirstApproval() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount * 2);

        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        assertEq(
            IERC20(mainnet.WETH).allowance(address(this), clonedProtocol),
            type(uint256).max,
            "Allowance should be max after first supply"
        );

        // Second supply must not revert — allowance guard skips re-approval when allowance >= amount
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);
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

    function _initWithMockAMMNoClone(MockAMMProtocol mockAmm) internal {
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).addAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        this.initialize(
            ownerAddress,
            guardAddress,
            mainnet.WETH,
            vaultAssets,
            lendingProtocols,
            stakingProtocols,
            _single(address(mockAmm)),
            intentProtocols,
            address(0),
            RiskSettings(0, 0, 0, 0),
            new AutoYield[](0),
            address(0)
        );
        _grantAssetManagerRole(assetManagerAddress);
    }

    function test_AddLiquidity_ClonesOnFirstUse() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initWithMockAMMNoClone(mockAmm);
        assertEq(this.getClonedProvider(address(mockAmm)), address(0), "no clone before first use");

        vm.prank(assetManagerAddress);
        this.addLiquidity(address(mockAmm), mainnet.WETH, 0, mainnet.USDT, 0, "");

        assertTrue(this.getClonedProvider(address(mockAmm)) != address(0), "addLiquidity must clone on first use");
    }

    // Both tokens deployed into an LP must be registered vault assets — otherwise addLiquidity is a path
    // to move unregistered tokens out around the asset allowlist.
    function test_AddLiquidity_RejectsUnregisteredToken0() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address unregistered = makeAddr("unregisteredToken");
        vm.prank(assetManagerAddress);
        vm.expectRevert(NotRegistered.selector);
        this.addLiquidity(address(mockAmm), unregistered, 1 ether, mainnet.USDT, 0, "");
    }

    function test_AddLiquidity_RejectsUnregisteredToken1() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address unregistered = makeAddr("unregisteredToken");
        vm.prank(assetManagerAddress);
        vm.expectRevert(NotRegistered.selector);
        this.addLiquidity(address(mockAmm), mainnet.WETH, 1 ether, unregistered, 1 ether, "");
    }

    // An add with both tokens registered is allowed.
    function test_AddLiquidity_SucceedsWithRegisteredTokens() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        deal(mainnet.WETH, address(this), 1000 ether);

        vm.prank(assetManagerAddress);
        this.addLiquidity(address(mockAmm), mainnet.WETH, 800 ether, mainnet.USDT, 0, "");
    }

    function test_RemoveLiquidity_RevertsWithoutClone() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initWithMockAMMNoClone(mockAmm);
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidAMMProtocol.selector);
        this.removeLiquidity(address(mockAmm), abi.encode(uint256(7)));
    }

    function test_DecreaseLiquidity_RevertsWithoutClone() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initWithMockAMMNoClone(mockAmm);
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidAMMProtocol.selector);
        this.decreaseLiquidity(address(mockAmm), abi.encode(uint256(3)));
    }

    function test_ClaimAMMFees_RevertsWithoutClone() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initWithMockAMMNoClone(mockAmm);
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidAMMProtocol.selector);
        this.claimAMMFees(address(mockAmm), "");
    }

    function test_ExitOps_RejectArbitraryUnregisteredProtocol() public {
        this.doInitialize();
        address attacker = makeAddr("maliciousProtocol");

        vm.startPrank(assetManagerAddress);
        vm.expectRevert(InvalidAMMProtocol.selector);
        this.removeLiquidity(attacker, abi.encode(uint256(1)));
        vm.expectRevert(InvalidLendingProtocol.selector);
        this.withdraw(attacker, mainnet.WETH, 1 ether);
        vm.expectRevert(InvalidStakingProtocol.selector);
        this.unstake(attacker, mainnet.WETH, 1 ether);
        vm.stopPrank();
    }

    function test_DecreaseLiquidityRevertOnlyAssetManager() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(NotAssetManager.selector);
        this.decreaseLiquidity(address(mockAmm), "");
    }

    function test_GetLiquidityFromDeprecatedAMMProtocol() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).deprecateAMMProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        assertEq(this.getLiquidities(_one(address(mockAmm)), _bytesOne(""))[0], 0);
    }

    // ─── Fuzz Tests ───────────────────────────────────────────────────────────

    function testFuzz_SetMinimalBalance_anyValueAccepted(uint256 minimalBalance) public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setMinimalBalances(_one(mainnet.WETH), _one(uint256(minimalBalance)));
    }

    function testFuzz_DisableRebalanceUntilTimestamp_cannotMovePrevTimestampEarlier(uint256 offset, uint256 reduction)
        public
    {
        offset = bound(offset, 2, 4 * 365 days);
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

    // ============ Auto yield ============

    function test_SetAutoYieldingRevertNotOwner() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.expectRevert(_roleError(stranger, DEFAULT_ADMIN_ROLE));
        vm.prank(stranger);
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol), true), _assetManager.autoYieldTrigger);
    }

    function test_SetAutoYieldingRevertAssetAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(address(0), address(aaveProtocol), true), _assetManager.autoYieldTrigger);
    }

    function test_SetAutoYieldingRevertUnregisteredLendingProtocol() public {
        this.doInitialize();
        // A staking protocol is not a valid supply route (and vice versa below).
        vm.expectRevert(InvalidLendingProtocol.selector);
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol), true), _assetManager.autoYieldTrigger);
    }

    function test_SetAutoYieldingRevertUnregisteredStakingProtocol() public {
        this.doInitialize();
        vm.expectRevert(InvalidStakingProtocol.selector);
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol), false), _assetManager.autoYieldTrigger);
    }

    function test_SetAutoYieldings_batchSetsMultipleRoutes() public {
        this.doInitialize();
        AutoYield[] memory routes = new AutoYield[](2);
        routes[0] = AutoYield({asset: mainnet.WETH, protocol: address(aaveProtocol), isSupplying: true});
        routes[1] = AutoYield({asset: WBTC, protocol: address(aaveProtocol), isSupplying: true});

        vm.prank(ownerAddress);
        this.setAutoYieldings(routes, _assetManager.autoYieldTrigger);

        (address p0, bool s0) = _getAutoYieldingOne(mainnet.WETH);
        assertEq(p0, address(aaveProtocol));
        assertTrue(s0);
        (address p1,) = _getAutoYieldingOne(WBTC);
        assertEq(p1, address(aaveProtocol));
    }

    // The merged setter: routes AND the keeper land in ONE transaction, and an
    // empty routes array is the trigger-only form.
    function test_SetAutoYieldings_setsRoutesAndTriggerInOneCall() public {
        this.doInitialize();
        address keeper = makeAddr("keeper");
        AutoYield[] memory routes = new AutoYield[](1);
        routes[0] = AutoYield({asset: mainnet.WETH, protocol: address(aaveProtocol), isSupplying: true});

        vm.prank(ownerAddress);
        this.setAutoYieldings(routes, keeper);

        (address p,) = _getAutoYieldingOne(mainnet.WETH);
        assertEq(p, address(aaveProtocol));
        assertEq(_assetManager.autoYieldTrigger, keeper);

        // Trigger-only update: empty routes leave the route untouched.
        vm.prank(ownerAddress);
        this.setAutoYieldings(new AutoYield[](0), address(0));
        (p,) = _getAutoYieldingOne(mainnet.WETH);
        assertEq(p, address(aaveProtocol));
        assertEq(_assetManager.autoYieldTrigger, address(0));
    }

    function test_SetAndGetAutoYielding() public {
        this.doInitialize();
        (address protocol, bool isSupplying) = _getAutoYieldingOne(mainnet.WETH);
        assertEq(protocol, address(0));

        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol), true), _assetManager.autoYieldTrigger);
        (protocol, isSupplying) = _getAutoYieldingOne(mainnet.WETH);
        assertEq(protocol, address(aaveProtocol));
        assertTrue(isSupplying);

        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(0), true), _assetManager.autoYieldTrigger);
        (protocol,) = _getAutoYieldingOne(mainnet.WETH);
        assertEq(protocol, address(0));
    }

    // Sends native ETH to the vault, triggering receive() → wrap to WETH → auto-yield.
    // Clears any WETH the harness setup left behind first so the deposit is the only source.
    function _depositEth(uint256 amount) internal {
        deal(mainnet.WETH, address(this), 0);
        vm.deal(address(this), amount);
        (bool ok,) = address(this).call{value: amount}("");
        assertTrue(ok, "eth deposit failed");
    }

    function test_AutoYieldRevertNotTrigger() public {
        this.doInitialize();
        // Auto-yield is not permissionless: an unauthorized caller is rejected.
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(NotAutoYieldTrigger.selector);
        this.autoYield(_one(mainnet.WETH));
    }

    function test_AutoYieldTriggerCanSweep() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol), true), _assetManager.autoYieldTrigger);
        address keeper = makeAddr("keeper");
        vm.prank(ownerAddress);
        this.setAutoYieldings(new AutoYield[](0), keeper);
        assertEq(_assetManager.autoYieldTrigger, keeper);

        // The vault holds WETH (not from an ETH deposit) — the trigger sweeps it into the route.
        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(keeper);
        this.autoYield(_one(mainnet.WETH));

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        assertApproxEqAbs(IBittyV1LendingProtocol(clonedProtocol).getSuppliedBalance(mainnet.WETH), 1 ether, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_AutoYieldTriggerClearedRevokesAccess() public {
        this.doInitialize();
        address keeper = makeAddr("keeper");
        vm.prank(ownerAddress);
        this.setAutoYieldings(new AutoYield[](0), keeper);
        vm.prank(ownerAddress);
        this.setAutoYieldings(new AutoYield[](0), address(0));

        vm.prank(keeper);
        vm.expectRevert(NotAutoYieldTrigger.selector);
        this.autoYield(_one(mainnet.WETH));
    }

    function test_AutoYieldNoRouteKeepsWeth() public {
        this.doInitialize();
        _depositEth(1 ether);
        // No route configured → the deposit is wrapped but stays liquid in the vault.
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 1 ether);
    }

    function test_AutoYieldSupplyOnDeposit() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol), true), _assetManager.autoYieldTrigger);

        _depositEth(1 ether);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        assertApproxEqAbs(IBittyV1LendingProtocol(clonedProtocol).getSuppliedBalance(mainnet.WETH), 1 ether, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_AutoYieldStakeOnDeposit() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol), false), _assetManager.autoYieldTrigger);

        _depositEth(0.5 ether);

        assertApproxEqAbs(this.getStakedBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 0.5 ether, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_AutoYieldKeepsMinimalBalanceLiquid() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol), false), _assetManager.autoYieldTrigger);
        vm.prank(ownerAddress);
        this.setMinimalBalances(_one(mainnet.WETH), _one(uint256(0.3 ether)));

        _depositEth(1 ether);
        assertApproxEqAbs(this.getStakedBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 0.7 ether, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0.3 ether);
    }

    function test_AutoYieldNothingSpendableKeepsWeth() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol), false), _assetManager.autoYieldTrigger);
        vm.prank(ownerAddress);
        this.setMinimalBalances(_one(mainnet.WETH), _one(uint256(1 ether)));

        // Whole deposit sits at the liquid floor → nothing yielded, all WETH stays.
        _depositEth(1 ether);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 1 ether);
        assertEq(this.getStakedBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 0);
    }

    function test_AutoYieldSkippedAfterProtocolRemoved() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol), false), _assetManager.autoYieldTrigger);
        vm.prank(ownerAddress);
        this.updateStakingProtocols(new address[](0), stakingProtocols);

        // Route now invalid → auto-yield is a caught no-op; the deposit still succeeds.
        _depositEth(1 ether);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 1 ether);
    }

    function test_AutoYieldSkippedForDeprecatedProtocol() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol), false), _assetManager.autoYieldTrigger);
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).deprecateStakingProtocols(stakingProtocols);

        _depositEth(1 ether);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 1 ether);
    }

    // ============ Off-chain order authorization (isOffchainManager) ============

    function test_IsOffchainManager_TrueForAssetManager() public {
        this.doInitialize();
        assertTrue(this.isOffchainManager(assetManagerAddress));
    }

    function test_IsOffchainManager_FalseForZeroSigner() public {
        this.doInitialize();
        assertFalse(this.isOffchainManager(address(0)));
    }

    function test_IsOffchainManager_FalseForStranger() public {
        this.doInitialize();
        assertFalse(this.isOffchainManager(makeAddr("stranger")));
    }

    // ============ Off-chain order authorization (isOffchainOrderAuthorized) ============

    function test_IsOffchainOrderAuthorized_SucceedsForRegisteredAsset() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        assertTrue(this.isOffchainOrderAuthorized(assetManagerAddress, mainnet.WETH, WBTC, 0.5 ether));
    }

    function test_IsOffchainOrderAuthorized_SucceedsForStableCoinBuyLeg() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        assertTrue(this.isOffchainOrderAuthorized(assetManagerAddress, mainnet.WETH, mainnet.USDC, 0.5 ether));
    }

    function test_IsOffchainOrderAuthorized_FalseForZeroSigner() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        assertFalse(this.isOffchainOrderAuthorized(address(0), mainnet.WETH, WBTC, 0.5 ether));
    }

    function test_IsOffchainOrderAuthorized_FalseForNonManager() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        assertFalse(this.isOffchainOrderAuthorized(makeAddr("stranger"), mainnet.WETH, WBTC, 0.5 ether));
    }

    function test_IsOffchainOrderAuthorized_FalseWhenTradingPaused() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(block.timestamp + 1 days);
        assertFalse(this.isOffchainOrderAuthorized(assetManagerAddress, mainnet.WETH, WBTC, 0.5 ether));
    }

    function test_IsOffchainOrderAuthorized_FalseForUnregisteredBuyToken() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        assertFalse(
            this.isOffchainOrderAuthorized(assetManagerAddress, mainnet.WETH, makeAddr("randomToken"), 0.5 ether)
        );
    }

    function test_IsOffchainOrderAuthorized_FalseForInsufficientBalance() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        assertFalse(this.isOffchainOrderAuthorized(assetManagerAddress, mainnet.WETH, WBTC, 2 ether));
    }

    function test_IsOffchainOrderAuthorized_FalseBelowMinimalBalance() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(ownerAddress);
        this.setMinimalBalances(_one(mainnet.WETH), _one(uint256(1 ether)));
        assertFalse(this.isOffchainOrderAuthorized(assetManagerAddress, mainnet.WETH, WBTC, 0.5 ether));
    }

    // ============ EIP-1271 signature validation (isValidSignature) ============

    function test_IsValidSignature_NoProtocolsReturnsFailure() public {
        this.doInitialize();
        assertTrue(this.isValidSignature(keccak256("order"), hex"1234") == bytes4(0xffffffff));
    }

    function test_IsValidSignature_MatchViaIntentClone() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addIntentProtocols(_single(address(intent)));

        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateIntentProtocols(_single(address(intent)), new address[](0));

        assertTrue(this.isValidSignature(keccak256("order"), hex"abcd") == bytes4(0x1626ba7e));
    }

    // ============ prepareIntentTrade (one-tx trade setup) ============

    // Allow-listed either as a plain asset or a stablecoin — the Guard decides
    // which set a token lands in, and prepareIntentTrade must treat both as
    // "already added".
    function _hasAsset(address token) internal view returns (bool) {
        address[] memory assetList = this.getAssets();
        for (uint256 i; i < assetList.length; ++i) {
            if (assetList[i] == token) return true;
        }
        address[] memory stableList = this.getStableCoins();
        for (uint256 i; i < stableList.length; ++i) {
            if (stableList[i] == token) return true;
        }
        return false;
    }

    // A first gasless trade otherwise costs three owner/manager txs (register
    // the intent protocol, allow-list the buy asset, approve the relayer).
    // prepareIntentTrade does all three in one, and is idempotent.
    function test_PrepareIntentTrade_doesAllThreeInOneCall() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        address relayer = makeAddr("vaultRelayer");
        intent.setEndpoints(makeAddr("settlement"), relayer);
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addIntentProtocols(_single(address(intent)));

        // A token the Guard knows but this vault has NOT added — exactly the
        // case a first buy of a new asset hits.
        MockERC20 newToken = new MockERC20("NEW", "NEW", 18);
        address newAsset = address(newToken);
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addAssets(_single(newAsset));

        this.doInitialize();

        // Nothing is set up yet: no intent protocol, the asset isn't allow-listed.
        assertEq(this.getIntentProtocols().length, 0);
        assertFalse(_hasAsset(newAsset), "asset not allow-listed yet");

        address[] memory assets = _single(newAsset);
        address[] memory approve = _single(mainnet.WETH);
        vm.prank(ownerAddress);
        this.prepareIntentTrade(address(intent), assets, approve);

        assertEq(this.getIntentProtocols().length, 1, "intent protocol registered");
        assertEq(this.getIntentProtocols()[0], address(intent));
        assertTrue(_hasAsset(newAsset), "buy asset allow-listed");
        assertEq(
            IERC20(mainnet.WETH).allowance(address(this), relayer),
            type(uint256).max,
            "relayer approved for the sell token"
        );
    }

    // Called again before every order, so re-running must be a no-op rather
    // than reverting on the already-registered protocol/asset.
    function test_PrepareIntentTrade_isIdempotent() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        intent.setEndpoints(makeAddr("settlement"), makeAddr("vaultRelayer"));
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addIntentProtocols(_single(address(intent)));
        this.doInitialize();

        address[] memory assets = _single(WBTC);
        address[] memory approve = _single(mainnet.WETH);
        vm.startPrank(ownerAddress);
        this.prepareIntentTrade(address(intent), assets, approve);
        this.prepareIntentTrade(address(intent), assets, approve);
        vm.stopPrank();

        assertEq(this.getIntentProtocols().length, 1, "no duplicate protocol");
        assertTrue(_hasAsset(WBTC));
    }

    // Everything already in place: the call must still succeed after the owner
    // has permanently locked adding protocols/assets (nothing new is added).
    function test_PrepareIntentTrade_worksWhenAddingLockedAndNothingNew() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        intent.setEndpoints(makeAddr("settlement"), makeAddr("vaultRelayer"));
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addIntentProtocols(_single(address(intent)));
        this.doInitialize();

        vm.startPrank(ownerAddress);
        this.prepareIntentTrade(address(intent), _single(WBTC), new address[](0));
        this.disableAddingProtocols();
        this.disableAddingAssets();
        // Same inputs, now with adding locked — no new registration is needed,
        // so it must not revert.
        this.prepareIntentTrade(address(intent), _single(WBTC), _single(mainnet.WETH));
        vm.stopPrank();

        assertTrue(_hasAsset(WBTC));
    }

    function test_PrepareIntentTrade_revertsForNonOwner() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        this.prepareIntentTrade(address(intent), new address[](0), new address[](0));
    }

    // ============ simpleStake / simpleSupply (one-tx first yield) ============

    // A first lend into a protocol the vault hasn't enabled otherwise costs two
    // txs (owner registers it, manager supplies). For an owner who is also the
    // manager this does both at once.
    function test_SimpleSupply_registersProtocolAndSupplies() public {
        this.doInitializeWithoutProtocols();
        // The owner is also the asset manager — the single-user setup.
        _grantAssetManagerRole(ownerAddress);
        assertEq(this.getLendingProtocols().length, 0, "no lending protocol yet");

        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.prank(ownerAddress);
        this.simpleSupply(address(aaveProtocol), mainnet.WETH, amount);

        assertEq(this.getLendingProtocols().length, 1, "protocol registered");
        assertApproxEqAbs(this.getSuppliedBalances(_one(address(aaveProtocol)), _one(mainnet.WETH))[0], amount, 10);
    }

    function test_SimpleStake_registersProtocolAndStakes() public {
        this.doInitializeWithoutProtocols();
        _grantAssetManagerRole(ownerAddress);
        assertEq(this.getStakingProtocols().length, 0, "no staking protocol yet");

        uint256 amount = 0.1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.prank(ownerAddress);
        this.simpleStake(address(lidoProtocol), mainnet.WETH, amount);

        assertEq(this.getStakingProtocols().length, 1, "protocol registered");
        assertGt(this.getStakedBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 0);
    }

    // Already-registered protocol: no re-add (which would revert once adding is
    // locked), just the supply.
    function test_SimpleSupply_skipsRegistrationWhenAlreadyEnabled() public {
        this.doInitialize();
        _grantAssetManagerRole(ownerAddress);
        assertEq(this.getLendingProtocols().length, 1);

        vm.prank(ownerAddress);
        this.disableAddingProtocols();

        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.prank(ownerAddress);
        this.simpleSupply(address(aaveProtocol), mainnet.WETH, amount);

        assertEq(this.getLendingProtocols().length, 1, "still just the one");
    }

    // An owner who is NOT the asset manager can't move funds this way — they
    // keep the two-step path (register, then the manager supplies).
    function test_SimpleSupply_revertsWhenOwnerIsNotAssetManager() public {
        this.doInitialize();
        _grantAssetManagerRole(assetManagerAddress);

        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(ownerAddress);
        vm.expectRevert(NotAssetManager.selector);
        this.simpleSupply(address(aaveProtocol), mainnet.WETH, 1 ether);
    }

    function test_SimpleStake_revertsForNonOwner() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(assetManagerAddress);
        vm.expectRevert();
        this.simpleStake(address(lidoProtocol), mainnet.WETH, 1 ether);
    }

    // ---- simpleWithdraw / simpleUnstake (exit + clear route in one tx) ----

    // Exiting an auto-yielded position is otherwise two txs (clear the route,
    // then withdraw) or an EIP-5792 batch the wallet may not support.
    function test_SimpleWithdraw_clearsRouteAndWithdrawsInOneCall() public {
        this.doInitialize();
        _grantAssetManagerRole(ownerAddress);

        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.startPrank(ownerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, amount);
        // Route set: without clearing it the keeper would re-supply the funds.
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol), true), _assetManager.autoYieldTrigger);
        (address routed,) = _getAutoYieldingOne(mainnet.WETH);
        assertEq(routed, address(aaveProtocol), "route is set");

        this.simpleWithdraw(address(aaveProtocol), mainnet.WETH, 0.5 ether, true);
        vm.stopPrank();

        (address after_,) = _getAutoYieldingOne(mainnet.WETH);
        assertEq(after_, address(0), "route cleared in the same tx");
        assertGe(IERC20(mainnet.WETH).balanceOf(address(this)), 0.5 ether, "funds back in the vault");
    }

    // clearRoute = false leaves the route alone (a partial exit that should keep
    // auto-yielding the rest).
    function test_SimpleWithdraw_keepsRouteWhenNotClearing() public {
        this.doInitialize();
        _grantAssetManagerRole(ownerAddress);

        deal(mainnet.WETH, address(this), 1 ether);
        vm.startPrank(ownerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, 1 ether);
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol), true), _assetManager.autoYieldTrigger);
        this.simpleWithdraw(address(aaveProtocol), mainnet.WETH, 0.25 ether, false);
        vm.stopPrank();

        (address routed,) = _getAutoYieldingOne(mainnet.WETH);
        assertEq(routed, address(aaveProtocol), "route untouched");
    }

    function test_SimpleUnstake_clearsRouteAndUnstakesInOneCall() public {
        this.doInitialize();
        _grantAssetManagerRole(ownerAddress);

        uint256 amount = 0.2 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.startPrank(ownerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, amount);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol), false), _assetManager.autoYieldTrigger);

        this.simpleUnstake(address(lidoProtocol), mainnet.WETH, 0.1 ether, true);
        vm.stopPrank();

        (address routed,) = _getAutoYieldingOne(mainnet.WETH);
        assertEq(routed, address(0), "route cleared in the same tx");
    }

    function test_SimpleWithdraw_revertsWhenOwnerIsNotAssetManager() public {
        this.doInitialize();
        _grantAssetManagerRole(assetManagerAddress);
        vm.prank(ownerAddress);
        vm.expectRevert(NotAssetManager.selector);
        this.simpleWithdraw(address(aaveProtocol), mainnet.WETH, 1, true);
    }

    function test_SimpleUnstake_revertsForNonOwner() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        vm.expectRevert();
        this.simpleUnstake(address(lidoProtocol), mainnet.WETH, 1, true);
    }

    // Completes the role matrix: every one-tx entry point rejects BOTH a
    // non-owner and an owner who isn't the vault's asset manager.
    function test_SimpleUnstake_revertsWhenOwnerIsNotAssetManager() public {
        this.doInitialize();
        _grantAssetManagerRole(assetManagerAddress);
        vm.prank(ownerAddress);
        vm.expectRevert(NotAssetManager.selector);
        this.simpleUnstake(address(lidoProtocol), mainnet.WETH, 1, true);
    }

    function test_SimpleWithdraw_revertsForNonOwner() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        vm.expectRevert();
        this.simpleWithdraw(address(aaveProtocol), mainnet.WETH, 1, true);
    }

    // End-to-end proof of what prepareIntentTrade is for: a gasless order whose
    // BUY leg isn't allow-listed is refused by the vault's authorizer (CoW then
    // rejects the signature, which is the opaque "failed to buy" users hit).
    // One prepareIntentTrade call makes the very same order authorized.
    function test_PrepareIntentTrade_makesPreviouslyUnbuyableTokenAuthorized() public {
        MockERC20 newToken = new MockERC20("BUYME", "BUYME", 18);
        MockIntentProtocol intent = new MockIntentProtocol();
        intent.setEndpoints(makeAddr("settlement"), makeAddr("vaultRelayer"));
        vm.startPrank(tx.origin);
        BittyV1Guard(guardAddress).addAssets(_single(address(newToken)));
        BittyV1Guard(guardAddress).addIntentProtocols(_single(address(intent)));
        vm.stopPrank();

        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);

        // Before: the vault can't receive the token, so the order is refused.
        assertFalse(
            this.isOffchainOrderAuthorized(assetManagerAddress, mainnet.WETH, address(newToken), 0.5 ether),
            "unlisted buy token must be refused"
        );

        vm.prank(ownerAddress);
        this.prepareIntentTrade(address(intent), _single(address(newToken)), _single(mainnet.WETH));

        // After: same order, now authorized — one tx did all the setup.
        assertTrue(
            this.isOffchainOrderAuthorized(assetManagerAddress, mainnet.WETH, address(newToken), 0.5 ether),
            "prepared order must be authorized"
        );
    }

    // ---- mirror cases + skip branches for the one-tx entry points ----

    function test_SimpleStake_revertsWhenOwnerIsNotAssetManager() public {
        this.doInitialize();
        _grantAssetManagerRole(assetManagerAddress);

        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(ownerAddress);
        vm.expectRevert(NotAssetManager.selector);
        this.simpleStake(address(lidoProtocol), mainnet.WETH, 1 ether);
    }

    function test_SimpleSupply_revertsForNonOwner() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        // The asset manager alone can't register a protocol, so this path is
        // owner-gated even though the manager may supply via the facet.
        vm.prank(assetManagerAddress);
        vm.expectRevert();
        this.simpleSupply(address(aaveProtocol), mainnet.WETH, 1 ether);
    }

    function test_SimpleStake_skipsRegistrationWhenAlreadyEnabled() public {
        this.doInitialize();
        _grantAssetManagerRole(ownerAddress);
        assertEq(this.getStakingProtocols().length, 1);

        vm.prank(ownerAddress);
        this.disableAddingProtocols();

        deal(mainnet.WETH, address(this), 0.1 ether);
        vm.prank(ownerAddress);
        this.simpleStake(address(lidoProtocol), mainnet.WETH, 0.1 ether);

        assertEq(this.getStakingProtocols().length, 1, "still just the one");
        assertGt(this.getStakedBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 0);
    }

    // address(0) = "don't touch the intent protocol", so the call can be used to
    // only allow-list assets.
    function test_PrepareIntentTrade_zeroProtocolOnlyAddsAssets() public {
        MockERC20 newToken = new MockERC20("NEW2", "NEW2", 18);
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addAssets(_single(address(newToken)));
        this.doInitialize();

        vm.prank(ownerAddress);
        this.prepareIntentTrade(address(0), _single(address(newToken)), new address[](0));

        assertEq(this.getIntentProtocols().length, 0, "no protocol registered");
        assertTrue(_hasAsset(address(newToken)), "asset still allow-listed");
    }

    // Mixed input: one asset already allow-listed, one not — only the missing
    // one is added (the filter that keeps a locked-adding vault working).
    function test_PrepareIntentTrade_addsOnlyMissingAssets() public {
        MockERC20 newToken = new MockERC20("NEW3", "NEW3", 18);
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addAssets(_single(address(newToken)));
        this.doInitialize();

        // WETH is already on the vault; the mock token is not.
        assertTrue(_hasAsset(mainnet.WETH));
        assertFalse(_hasAsset(address(newToken)));

        vm.prank(ownerAddress);
        this.prepareIntentTrade(address(0), _two(mainnet.WETH, address(newToken)), new address[](0));

        assertTrue(_hasAsset(mainnet.WETH), "existing asset untouched");
        assertTrue(_hasAsset(address(newToken)), "missing asset added");
    }

    // Nothing to do at all — must be a clean no-op rather than reverting.
    function test_PrepareIntentTrade_emptyArraysIsNoOp() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.prepareIntentTrade(address(0), new address[](0), new address[](0));
        assertEq(this.getIntentProtocols().length, 0);
    }

    // ============ AssetManagerLogic revert / branch coverage ============

    function test_SetMinimalBalances_batchSetsAllAndEmits() public {
        this.doInitialize();
        address[] memory assets = new address[](2);
        uint256[] memory values = new uint256[](2);
        assets[0] = mainnet.WETH;
        assets[1] = WBTC;
        values[0] = 1 ether;
        values[1] = 42;

        vm.prank(ownerAddress);
        vm.expectEmit(false, false, false, true);
        emit IBittyV1Owner.MinimalBalancesSet(assets, values);
        this.setMinimalBalances(assets, values);

        assertEq(this.minimalBalance(mainnet.WETH), 1 ether);
        assertEq(this.minimalBalance(WBTC), 42);
    }

    function test_SetMinimalBalances_revertsOnLengthMismatch() public {
        this.doInitialize();
        address[] memory assets = new address[](2);
        assets[0] = mainnet.WETH;
        assets[1] = WBTC;
        vm.prank(ownerAddress);
        vm.expectRevert(ArrayLengthMismatch.selector);
        this.setMinimalBalances(assets, _one(uint256(1 ether)));
    }

    function test_SetMinimalBalances_onlyOwner() public {
        this.doInitialize();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        this.setMinimalBalances(_one(mainnet.WETH), _one(uint256(1 ether)));
    }

    function test_SetMinimalBalanceRevertAddressZero() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        vm.expectRevert(AddressZero.selector);
        this.setMinimalBalances(_one(address(0)), _one(uint256(1)));
    }

    function test_WithdrawRevertInsufficientBalance() public {
        this.doInitialize();
        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        this.supply(address(aaveProtocol), mainnet.WETH, supplyAmount);

        vm.prank(assetManagerAddress);
        vm.expectRevert(InsufficientBalance.selector);
        this.withdraw(address(aaveProtocol), mainnet.WETH, supplyAmount * 2);
    }

    function test_StakeRevertAddressZero() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        vm.expectRevert(AddressZero.selector);
        this.stake(address(lidoProtocol), address(0), 1 ether);
    }

    function test_UnstakeRevertAddressZero() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        vm.expectRevert(AddressZero.selector);
        this.unstake(address(lidoProtocol), address(0), 1 ether);
    }

    function test_UnstakeRevertInsufficientBalance() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.stake(address(lidoProtocol), mainnet.WETH, 1 ether);

        vm.prank(assetManagerAddress);
        vm.expectRevert(InsufficientBalance.selector);
        this.unstake(address(lidoProtocol), mainnet.WETH, 100 ether);
    }

    function test_GetStakedBalanceRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        this.getStakedBalances(_one(address(lidoProtocol)), _one(address(0)));
    }

    function test_ClaimUnstakedRevertInvalidStakingProtocol() public {
        this.doInitialize();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidStakingProtocol.selector);
        this.claimUnstaked(address(lidoProtocol), ids);
    }

    function test_AddStakingProtocolsRevertNotRegistered() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        vm.expectRevert(NotRegistered.selector);
        this.updateStakingProtocols(_single(makeAddr("unregisteredStaking")), new address[](0));
    }

    function test_AddLiquidityRevertInvalidAMMProtocol() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidAMMProtocol.selector);
        this.addLiquidity(makeAddr("unregisteredAMM"), mainnet.WETH, 0, mainnet.USDT, 0, "");
    }

    function test_DisableRebalanceUntilTimestampZeroIsNoop() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        this.disableRebalanceUntilTimestamp(0);
    }

    function test_ApproveIntentRelayerRevertInvalidIntentProtocol() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidIntentProtocol.selector);
        this.approveIntentRelayer(makeAddr("unregisteredIntent"), mainnet.WETH);
    }

    function test_ApproveIntentRelayerRevertDeprecated() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addIntentProtocols(_single(address(intent)));

        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateIntentProtocols(_single(address(intent)), new address[](0));

        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).deprecateIntentProtocols(_single(address(intent)));

        vm.prank(assetManagerAddress);
        vm.expectRevert(Deprecated.selector);
        this.approveIntentRelayer(address(intent), mainnet.WETH);
    }

    function test_ClaimAMMFeesSuccess() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        vm.prank(assetManagerAddress);
        this.claimAMMFees(address(mockAmm), abi.encode(uint256(1)));
    }

    function test_RemoveLiquiditySuccess() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        address clone = this.getClonedProvider(address(mockAmm));
        bytes memory data = abi.encode(uint256(3));
        vm.prank(assetManagerAddress);
        this.removeLiquidity(address(mockAmm), data);
        assertEq(MockAMMProtocol(clone).removeLiquidityCallCount(), 1);
    }

    function test_AddLiquidityApprovesBothTokens() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);
        deal(mainnet.WETH, address(this), 10 ether);
        deal(mainnet.USDT, address(this), 10_000 * 1e6);
        vm.prank(assetManagerAddress);
        this.addLiquidity(address(mockAmm), mainnet.WETH, 5 ether, mainnet.USDT, 5_000 * 1e6, "");
    }

    // ============ DeFi facet view getters ============

    function test_Facet_ViewGetters() public {
        this.doInitialize();
        assertEq(address(this.guard()), guardAddress);
        assertEq(this.getLendingProtocols().length, 1);
        assertEq(this.getStakingProtocols().length, 1);
        assertEq(this.getAMMProtocols().length, 1);
        assertEq(this.getIntentProtocols().length, 0);
        vm.prank(ownerAddress);
        this.setMinimalBalances(_one(WBTC), _one(uint256(42)));
        assertEq(this.minimalBalance(WBTC), 42);
    }

    // ============ Vault owner surface (BittyV1Vault + logic passthroughs) ============

    function test_WethAddress() public {
        this.doInitialize();
        assertEq(this.wethAddress(), mainnet.WETH);
    }

    function test_IsAddingAssetsDisabled_DefaultFalse() public {
        this.doInitialize();
        assertFalse(this.isAddingAssetsDisabled());
    }

    function test_ClearAssetManager_viaSetToZero() public {
        this.doInitialize();
        assertEq(this.getAssetManager(), assetManagerAddress);
        // setAssetManager(address(0)) clears it — the former removeAssetManager.
        vm.prank(ownerAddress);
        this.setAssetManager(address(0));
        assertEq(this.getAssetManager(), address(0));
    }

    function test_AddAMMProtocolsEmitsAndKeepsRegistered() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateAMMProtocols(_single(address(uniswapV3Protocol)), new address[](0));
        assertEq(this.getAMMProtocols().length, 1);
    }

    function test_RemoveIntentProtocols() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addIntentProtocols(_single(address(intent)));

        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateIntentProtocols(_single(address(intent)), new address[](0));
        assertEq(this.getIntentProtocols().length, 1);

        vm.prank(ownerAddress);
        this.updateIntentProtocols(new address[](0), _single(address(intent)));
        assertEq(this.getIntentProtocols().length, 0);
    }

    function test_ApproveIntentRelayerSuccess() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        address relayer = makeAddr("relayer");
        intent.setEndpoints(makeAddr("settlement"), relayer);
        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addIntentProtocols(_single(address(intent)));

        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateIntentProtocols(_single(address(intent)), new address[](0));

        vm.prank(assetManagerAddress);
        this.approveIntentRelayer(address(intent), mainnet.WETH);
        assertEq(IERC20(mainnet.WETH).allowance(address(this), relayer), type(uint256).max);
    }

    function test_SendRevertArrayLengthMismatch() public {
        this.doInitialize();
        address[] memory recipients = _single(makeAddr("recipient"));
        address[] memory sendAssets = _single(mainnet.WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        address[] memory stakingProtos = _single(address(lidoProtocol));
        uint256[] memory stakingAmounts = new uint256[](0); // wrong length -> mismatch
        address[] memory emptyAddrs = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        vm.prank(ownerAddress);
        vm.expectRevert(ArrayLengthMismatch.selector);
        this.send(recipients, sendAssets, amounts, stakingProtos, stakingAmounts, emptyAddrs, emptyAmounts);
    }

    // addLiquidity to an AMM whose clone exposes positionAssetManager() (Uniswap
    // V3-style NFT positions) sets the NFT operator approval once, then skips it.
    function test_AddLiquidity_ApprovesPositionNFTOnce() public {
        MockPositionNFT nft = new MockPositionNFT();
        MockAMMWithNFT mockAmm = new MockAMMWithNFT(address(nft));
        _initializeWithMockAMM(MockAMMProtocol(address(mockAmm)));
        address clone = this.getClonedProvider(address(mockAmm));
        deal(mainnet.WETH, address(this), 10 ether);

        assertFalse(nft.isApprovedForAll(address(this), clone));
        vm.prank(assetManagerAddress);
        this.addLiquidity(address(mockAmm), mainnet.WETH, 1 ether, mainnet.USDT, 0, "");
        assertTrue(nft.isApprovedForAll(address(this), clone), "operator approval granted");

        // Second add: already approved, so the setApprovalForAll branch is skipped.
        vm.prank(assetManagerAddress);
        this.addLiquidity(address(mockAmm), mainnet.WETH, 1 ether, mainnet.USDT, 0, "");
    }
}

// A minimal ERC-721-style operator-approval registry, enough to exercise the
// vault's _approveNFTIfNeeded (isApprovedForAll / setApprovalForAll).
contract MockPositionNFT {
    mapping(address => mapping(address => bool)) private _approvals;

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _approvals[owner][operator];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _approvals[msg.sender][operator] = approved;
    }
}

// AMM protocol whose clones report a position NFT (like Uniswap V3), so
// addLiquidity triggers the NFT operator-approval path. `nft` is immutable so it
// survives the EIP-1167 clone delegatecall.
contract MockAMMWithNFT is MockAMMProtocol {
    address public immutable nft;

    constructor(address nft_) {
        nft = nft_;
    }

    function positionAssetManager() external view returns (address) {
        return nft;
    }
}
