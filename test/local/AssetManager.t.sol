// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    AmountIsZero,
    AddressZero,
    InsufficientBalance,
    ArrayLengthMismatch,
    AutoYield,
    AddingAssetsDisabled,
    AddingProtocolsDisabled
} from "../../src/interfaces/IBittyV1Vault.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {vaultProtocols} from "../helpers/VaultSets.sol";
import {guardAddAssets, guardAddStableCoins, guardAddProtocols} from "../helpers/GuardRegister.sol";
import {GUARD_DEPLOYER} from "../helpers/GuardDeployer.sol";
import {
    InvalidDepositableProtocol,
    InvalidWithdrawableProtocol,
    InvalidAMMProtocol,
    InvalidIntentProtocol,
    NotAssetManager,
    AssetManagerExpired,
    AssetManagerExpiryInPast,
    disableTradeUntilTimestampTooEarly,
    disableTradeUntilTimestampTooLong
} from "../../src/interfaces/IBittyV1AssetManager.sol";
import {Deprecated, NotRegistered} from "../../src/interfaces/IBittyV1Vault.sol";
import {IBittyV1Withdrawable} from "protocol-contracts/src/interfaces/IBittyV1Withdrawable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {mainnet} from "protocol-contracts/script/addresses.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {MockCategoryProtocol} from "../helpers/MockCategoryProtocol.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";
import {BittyV1VaultHarness} from "../helpers/BittyV1VaultHarness.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {ProtocolTestSetup} from "../helpers/ProtocolTestSetup.sol";
import {MockAMMProtocol} from "../helpers/MockAMMProtocol.sol";
import {MockIntentProtocol} from "../helpers/MockIntentProtocol.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";
import {effectiveAssetManager} from "../helpers/AssetManagerView.sol";
import {INTENT_ID} from "../helpers/CategoryIds.sol";
import {MockStakingProtocol} from "../helpers/MockStakingProtocol.sol";

contract TestAssetManager is ProtocolTestSetup, BittyV1VaultHarness {
    constructor() BittyV1VaultHarness(AUTO_YIELD_KEEPER_FOR_TEST) {}

    address internal constant AUTO_YIELD_KEEPER_FOR_TEST = address(0xA07E1D);

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

        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        deployCodeTo("BittyV1Guard.sol:BittyV1Guard", BITTY_GUARD);
        vm.stopPrank();
        BittyV1Guard guard = BittyV1Guard(BITTY_GUARD);
        guardAddress = address(guard);

        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guard.grantRole(guard.ASSET_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.PROTOCOL_MANAGER_ROLE(), tx.origin);
        guardAddAssets(address(guard), _two(mainnet.WETH, WBTC));
        guardAddStableCoins(address(guard), _two(mainnet.USDT, mainnet.USDC));
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
        this.setAssetManager(assetManager, 0);
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
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _single(address(mockAmm)));
        vm.stopPrank();

        this.initialize(ownerAddress, mainnet.WETH, address(0), 0);
        _enableAssets();
        address[] memory none = new address[](0);
        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(mockAmm)), none);
        _grantAssetManagerRole(assetManagerAddress);
        _cloneProtocolForTest(address(mockAmm));
    }

    function _deprecateVaultAMMProtocols() internal {
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        BittyV1Guard(guardAddress).deprecateProtocols(ammProtocols);
    }

    /// @dev The vault expresses ownership through Ownable now, so `role` is vestigial — kept so the
    ///      call sites still read as "this caller lacks that authority".
    function _roleError(address account, bytes32) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, account);
    }

    /// Neither assets nor protocols are initialize parameters any more, so add them the way
    /// production does: lazily, by the owner, once the vault exists.
    function _enableAssets() internal {
        vm.prank(ownerAddress);
        this.updateAssets(vaultAssets, new address[](0));
    }

    /**
     * @dev How many protocols {doInitialize} leaves in the vault's list: one lending, one staking,
     *      one AMM. The list is flat now, so a test about ONE category still sees the other two, and
     *      counts are written relative to this rather than as a bare per-category number.
     */
    uint256 internal constant ENABLED_AT_INIT = 3;

    function _enableProtocols() internal {
        address[] memory none = new address[](0);
        vm.startPrank(ownerAddress);
        if (lendingProtocols.length > 0) this.updateProtocols(lendingProtocols, none);
        if (stakingProtocols.length > 0) this.updateProtocols(stakingProtocols, none);
        if (ammProtocols.length > 0) this.updateProtocols(ammProtocols, none);
        if (intentProtocols.length > 0) this.updateProtocols(intentProtocols, none);
        vm.stopPrank();
    }

    function doInitialize() public {
        this.initialize(ownerAddress, mainnet.WETH, address(0), 0);
        _enableAssets();
        _enableProtocols();
        _grantAssetManagerRole(assetManagerAddress);
    }

    /// @dev Same vault, but with NO yield protocols enabled — the state a fresh
    ///      minimal activation leaves behind, which the simple* entry points
    ///      are built for.
    function doInitializeWithoutProtocols() public {
        this.initialize(ownerAddress, mainnet.WETH, address(0), 0);
        _enableAssets();
        _grantAssetManagerRole(assetManagerAddress);
    }

    function test_DisableAddingProtocols_BlocksAllProtocolTypesIncludingIntent() public {
        address intentProto = address(new MockCategoryProtocol(0x1626ba7e));
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _single(intentProto));
        vm.stopPrank();

        this.doInitialize();

        vm.startPrank(ownerAddress);
        this.disableAddingProtocols();
        assertTrue(this.isAddingProtocolsDisabled(), "adding protocols must be locked");

        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.updateProtocols(_single(address(aaveProtocol)), new address[](0));

        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.updateProtocols(_single(address(lidoProtocol)), new address[](0));

        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.updateProtocols(_single(address(uniswapV3Protocol)), new address[](0));

        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.updateProtocols(_single(intentProto), new address[](0));

        vm.stopPrank();
    }

    function test_DisableAddingProtocols_BlocksIntentEvenForRegisteredProtocol() public {
        address intentProto = address(new MockCategoryProtocol(0x1626ba7e));
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _single(intentProto));
        vm.stopPrank();

        this.doInitialize();

        vm.prank(ownerAddress);
        this.updateProtocols(_single(intentProto), new address[](0));

        vm.prank(ownerAddress);
        this.disableAddingProtocols();

        vm.prank(ownerAddress);
        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.updateProtocols(_single(intentProto), new address[](0));
    }

    // One-element array builders so a single-asset call reads
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

    function _getAutoYieldingOne(address asset) internal returns (address protocol) {
        return this.getAutoYieldings(_one(asset))[0];
    }

    function _route(address asset, address protocol) private pure returns (AutoYield[] memory arr) {
        arr = new AutoYield[](1);
        arr[0] = AutoYield({asset: asset, protocol: protocol});
    }

    function test_SupplyRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(assetManagerAddress);
        this.deposit(address(aaveProtocol), address(0), 1 ether);
    }

    function test_SupplyRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.deposit(address(aaveProtocol), address(mainnet.WETH), 0);
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

    function test_SupplyRevertInvalidDepositableProtocol() public {
        this.doInitialize();
        address invalidLendingProtocol = address(new AaveV3Protocol(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER));
        vm.expectRevert(InvalidDepositableProtocol.selector);
        vm.prank(assetManagerAddress);
        this.deposit(invalidLendingProtocol, address(mainnet.WETH), 1 ether);
    }

    function test_SupplySuccess() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        this.deposit(address(aaveProtocol), mainnet.WETH, supplyAmount);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        require(clonedProtocol != address(0), "Provider should be cloned");

        uint256 balanceAfter = IBittyV1Withdrawable(clonedProtocol).getBalance(mainnet.WETH);
        assertApproxEqAbs(balanceAfter, supplyAmount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_WithdrawSuccess() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        uint256 withdrawAmount = 0.5 ether;

        deal(mainnet.WETH, address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        this.deposit(address(aaveProtocol), mainnet.WETH, supplyAmount);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        uint256 balanceBefore = IERC20(mainnet.WETH).balanceOf(address(this));

        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), mainnet.WETH, withdrawAmount);

        uint256 balanceAfter = IERC20(mainnet.WETH).balanceOf(address(this));
        assertApproxEqAbs(balanceAfter - balanceBefore, withdrawAmount, 5);

        uint256 remaining = IBittyV1Withdrawable(clonedProtocol).getBalance(mainnet.WETH);
        assertApproxEqAbs(remaining, supplyAmount - withdrawAmount, 10);
    }

    function test_LendingProviderRevertIfNotRegistered() public {
        this.doInitialize();

        address invalidLendingProtocol = makeAddr("InvalidLendingProtocol");
        vm.expectRevert(InvalidDepositableProtocol.selector);
        vm.prank(assetManagerAddress);
        this.deposit(invalidLendingProtocol, address(mainnet.WETH), 1 ether);
    }

    function test_SupplyFromDeprecatedLendingProvider() public {
        this.doInitialize();
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        BittyV1Guard(guardAddress).deprecateProtocols(lendingProtocols);
        vm.expectRevert(Deprecated.selector);
        vm.prank(assetManagerAddress);
        this.deposit(address(aaveProtocol), address(mainnet.WETH), 1 ether);
    }

    function test_WithdrawMoneySuccessFromDeprecateLendingProvider() public {
        this.doInitialize();
        deal(address(mainnet.WETH), address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.deposit(address(aaveProtocol), address(mainnet.WETH), 1 ether);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        BittyV1Guard(guardAddress).deprecateProtocols(lendingProtocols);
        uint256 supplied = this.getBalances(_one(address(aaveProtocol)), _one(address(mainnet.WETH)))[0];
        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), address(mainnet.WETH), supplied);
    }

    function test_WithdrawWorksAfterLendingProtocolRemoved() public {
        this.doInitialize();
        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.prank(assetManagerAddress);
        this.deposit(address(aaveProtocol), mainnet.WETH, amount);

        vm.prank(ownerAddress);
        this.updateProtocols(new address[](0), _single(address(aaveProtocol)));

        vm.prank(assetManagerAddress);
        this.withdraw(address(aaveProtocol), mainnet.WETH, amount / 2);

        assertGt(IERC20(mainnet.WETH).balanceOf(address(this)), 0, "withdraw returned funds after removal");
    }

    function test_GetBalance() public {
        this.doInitialize();
        uint256 depositAmount = 5 ether;

        uint256 balance = this.getBalances(_one(address(aaveProtocol)), _one(address(mainnet.WETH)))[0];
        assertEq(balance, 0);

        deal(address(mainnet.WETH), address(this), depositAmount);
        IERC20(mainnet.WETH).approve(address(this), depositAmount);

        vm.prank(assetManagerAddress);
        this.deposit(address(aaveProtocol), address(mainnet.WETH), depositAmount);

        balance = this.getBalances(_one(address(aaveProtocol)), _one(address(mainnet.WETH)))[0];
        assertApproxEqAbs(balance, depositAmount, 10);
    }

    function test_GetBalance_UnusedLendingProtocol_ReturnsZero() public {
        this.doInitialize();
        assertEq(this.getBalances(_one(makeAddr("UnusedLendingProtocol")), _one(address(mainnet.WETH)))[0], 0);
    }

    function test_GetBalanceFromDeprecatedLendingProvider() public {
        this.doInitialize();
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        BittyV1Guard(guardAddress).deprecateProtocols(lendingProtocols);
        uint256 balance = this.getBalances(_one(address(aaveProtocol)), _one(address(mainnet.WETH)))[0];
        assertEq(balance, 0);
    }

    function test_SetTradeLimit_RevertsForNonOwner() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, bytes32(0)));
        this.setAssetManager(assetManagerAddress, 0);
    }

    function test_disableTradeUntilTimestampTooEarly_RevertsWhenNewTimestampEarlier() public {
        this.doInitialize();

        uint256 firstDisabledUntil = block.timestamp + 200;
        vm.prank(assetManagerAddress);
        this.disableTradeUntilTimestamp(firstDisabledUntil);

        uint256 earlierTimestamp = block.timestamp + 100;
        vm.expectRevert(disableTradeUntilTimestampTooEarly.selector);
        vm.prank(assetManagerAddress);
        this.disableTradeUntilTimestamp(earlierTimestamp);
    }

    function test_disableTradeUntilTimestamp_AllowsExactlyFourYears() public {
        this.doInitialize();

        vm.prank(assetManagerAddress);
        this.disableTradeUntilTimestamp(block.timestamp + 4 * 365 days);
    }

    function test_disableTradeUntilTimestamp_RevertsBeyondFourYears() public {
        this.doInitialize();

        vm.expectRevert(disableTradeUntilTimestampTooLong.selector);
        vm.prank(assetManagerAddress);
        this.disableTradeUntilTimestamp(block.timestamp + 4 * 365 days + 1);
    }

    function test_DisableAddingAssets_RevertsWhenNotOwnerOrAssetManager() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, bytes32(0)));
        this.disableAddingAssets();
    }

    function test_AddAssets_afterInit_addsStableCoinViaUnifiedPath() public {
        this.initialize(ownerAddress, mainnet.WETH, address(0), 0);
        vm.prank(ownerAddress);
        this.updateAssets(assets, new address[](0));
        _grantAssetManagerRole(assetManagerAddress);

        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(usdc);

        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddStableCoins(address(BittyV1Guard(guardAddress)), toAdd);

        vm.prank(ownerAddress);
        this.updateAssets(toAdd, new address[](0));

        // Routing is exclusive, so "it is a stable coin" is also the assertion that it is not a
        // plain asset - which is what the old asset-count line was standing in for.
        assertTrue(this.isStableCoinAllowed(address(usdc)), "added via the unified path");
    }

    function test_DisableAddingAssets_SucceedsAndAddAssetsReverts() public {
        this.doInitialize();

        MockERC20 mockDAI = new MockERC20("DAI", "DAI", 18);
        address[] memory newAssets = new address[](1);
        newAssets[0] = address(mockDAI);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddAssets(address(BittyV1Guard(guardAddress)), newAssets);

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
        this.deposit(address(lidoProtocol), mainnet.WETH, 1 ether);
    }

    function test_StakeRevertInvalidDepositableProtocol() public {
        this.doInitialize();
        address invalidStakingProvider = makeAddr("InvalidStakingProtocol");
        vm.expectRevert(InvalidDepositableProtocol.selector);
        vm.prank(assetManagerAddress);
        this.deposit(invalidStakingProvider, mainnet.WETH, 1 ether);
    }

    function test_StakeRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, 0);
    }

    function test_StakeSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        assertEq(this.getBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 0);

        vm.prank(assetManagerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, stakeAmount);

        address clonedProtocol = this.getClonedProvider(address(lidoProtocol));
        assertTrue(clonedProtocol != address(0));
        assertApproxEqAbs(IBittyV1Withdrawable(clonedProtocol).getBalance(mainnet.WETH), stakeAmount, 10);
        assertApproxEqAbs(this.getBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], stakeAmount, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_GetStakingBalance() public {
        this.doInitialize();
        assertEq(this.getBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 0);

        uint256 stakeAmount = 2 ether;
        deal(mainnet.WETH, address(this), stakeAmount);
        vm.prank(assetManagerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, stakeAmount);

        assertApproxEqAbs(this.getBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], stakeAmount, 10);
    }

    function test_GetStakingBalance_UnusedStakingProtocol_ReturnsZero() public {
        this.doInitialize();
        assertEq(this.getBalances(_one(makeAddr("UnusedStakingProtocol")), _one(mainnet.WETH))[0], 0);
    }

    function test_UnstakeSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 1 ether;
        uint256 unstakeAmount = 0.5 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        vm.prank(assetManagerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, stakeAmount);
        assertApproxEqAbs(this.getBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], stakeAmount, 10);

        vm.prank(assetManagerAddress);
        this.withdraw(address(lidoProtocol), mainnet.WETH, unstakeAmount);
        assertApproxEqAbs(
            this.getBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], stakeAmount - unstakeAmount, 10
        );

        uint256[] memory requestIds = this.getPendingWithdrawalIds(address(lidoProtocol));
        assertEq(requestIds.length, 1);

        vm.prank(assetManagerAddress);
        this.claimWithdrawals(address(lidoProtocol), requestIds);
    }

    function test_ClaimSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 0.1 ether;
        uint256 unstakeAmount = 0.05 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        vm.prank(assetManagerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, stakeAmount);
        vm.prank(assetManagerAddress);
        this.withdraw(address(lidoProtocol), mainnet.WETH, unstakeAmount);

        uint256[] memory requestIds = this.getPendingWithdrawalIds(address(lidoProtocol));
        assertEq(requestIds.length, 1);

        vm.prank(assetManagerAddress);
        this.claimWithdrawals(address(lidoProtocol), requestIds);
        // Lido withdrawals are not finalized immediately on a mainnet fork.
        assertEq(this.getPendingWithdrawalIds(address(lidoProtocol)).length, 1);
    }

    function test_ClaimRevertOnlyAssetManager() public {
        this.doInitialize();
        uint256[] memory requestIds = new uint256[](0);
        address stranger = makeAddr("subscribedStranger");
        vm.prank(stranger);
        vm.expectRevert(NotAssetManager.selector);
        this.claimWithdrawals(address(lidoProtocol), requestIds);
    }

    function test_RemoveLiquidityWorksAfterAMMProtocolRemoved() public {
        MockAMMProtocol mockAmm = new MockAMMProtocol();
        _initializeWithMockAMM(mockAmm);

        vm.prank(ownerAddress);
        this.updateProtocols(new address[](0), _single(address(mockAmm)));

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
        this.claimWithdrawals(address(lidoProtocol), requestIds);
    }

    function test_UnstakeRevertAmountIsZero() public {
        this.doInitialize();
        vm.expectRevert(AmountIsZero.selector);
        vm.prank(assetManagerAddress);
        this.withdraw(address(lidoProtocol), mainnet.WETH, 0);
    }

    function test_UnstakeWorksAfterStakingProtocolRemoved() public {
        this.doInitialize();
        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.prank(assetManagerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, amount);

        vm.prank(ownerAddress);
        this.updateProtocols(new address[](0), _single(address(lidoProtocol)));

        vm.prank(assetManagerAddress);
        this.withdraw(address(lidoProtocol), mainnet.WETH, amount / 2);

        uint256[] memory ids =
            IBittyV1Withdrawable(this.getClonedProvider(address(lidoProtocol))).getPendingWithdrawalIds();
        assertEq(ids.length, 1, "unstake request created after removal");
    }

    function test_GetUnstakeRequestIds() public {
        this.doInitialize();
        uint256[] memory ids = this.getPendingWithdrawalIds(address(lidoProtocol));
        assertEq(ids.length, 0);

        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, 1 ether);
        vm.prank(assetManagerAddress);
        this.withdraw(address(lidoProtocol), mainnet.WETH, 0.5 ether);

        ids = this.getPendingWithdrawalIds(address(lidoProtocol));
        assertEq(ids.length, 1);
    }

    function test_GetUnstakeRequestIds_UnusedStakingProtocol_ReturnsEmpty() public {
        this.doInitialize();
        assertEq(this.getPendingWithdrawalIds(makeAddr("UnusedStakingProtocol")).length, 0);
    }

    function test_SupplyAllowanceIsMaxAfterFirstApproval() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount * 2);

        vm.prank(assetManagerAddress);
        this.deposit(address(aaveProtocol), mainnet.WETH, supplyAmount);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        assertEq(
            IERC20(mainnet.WETH).allowance(address(this), clonedProtocol),
            type(uint256).max,
            "Allowance should be max after first supply"
        );

        // Second supply must not revert — allowance guard skips re-approval when allowance >= amount
        vm.prank(assetManagerAddress);
        this.deposit(address(aaveProtocol), mainnet.WETH, supplyAmount);
    }

    function test_SupplySucceedsWithPreExistingResidualAllowance() public {
        this.doInitialize();

        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount);

        address clonedProtocol = _cloneProtocolForTest(address(aaveProtocol));

        IERC20(mainnet.WETH).approve(clonedProtocol, 1);
        assertEq(IERC20(mainnet.WETH).allowance(address(this), clonedProtocol), 1);

        vm.prank(assetManagerAddress);
        this.deposit(address(aaveProtocol), mainnet.WETH, supplyAmount);

        assertApproxEqAbs(IBittyV1Withdrawable(clonedProtocol).getBalance(mainnet.WETH), supplyAmount, 10);
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
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        BittyV1Guard(guardAddress).deprecateProtocols(_single(address(mockAmm)));
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
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        BittyV1Guard(guardAddress).deprecateProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        bytes memory data = abi.encode(uint256(7));
        vm.prank(assetManagerAddress);
        this.removeLiquidity(address(mockAmm), data);

        assertEq(MockAMMProtocol(clone).removeLiquidityCallCount(), 1);
        assertEq(MockAMMProtocol(clone).lastRemoveData(), data);
    }

    function _initWithMockAMMNoClone(MockAMMProtocol mockAmm) internal {
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _single(address(mockAmm)));
        vm.stopPrank();

        this.initialize(ownerAddress, mainnet.WETH, address(0), 0);
        _enableAssets();
        address[] memory none = new address[](0);
        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(mockAmm)), none);
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
        // One exit for every protocol now, so there is one call and one answer. The exit does not ask
        // the guard anything: it looks for a clone, and a clone only exists for a protocol that passed
        // the guard when it was listed, so an address nobody listed has nothing to withdraw from.
        vm.expectRevert(InvalidWithdrawableProtocol.selector);
        this.withdraw(attacker, mainnet.WETH, 1 ether);
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
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        BittyV1Guard(guardAddress).deprecateProtocols(_single(address(mockAmm)));
        vm.stopPrank();

        assertEq(this.getLiquidities(_one(address(mockAmm)), _bytesOne(""))[0], 0);
    }

    // ─── Fuzz Tests ───────────────────────────────────────────────────────────

    function testFuzz_disableTradeUntilTimestamp_cannotMovePrevTimestampEarlier(uint256 offset, uint256 reduction)
        public
    {
        offset = bound(offset, 2, 4 * 365 days);
        reduction = bound(reduction, 1, offset);
        this.doInitialize();
        uint256 first = block.timestamp + offset;
        vm.prank(assetManagerAddress);
        this.disableTradeUntilTimestamp(first);
        vm.expectRevert(disableTradeUntilTimestampTooEarly.selector);
        vm.prank(assetManagerAddress);
        this.disableTradeUntilTimestamp(first - reduction);
    }

    function test_StakeSucceedsWithPreExistingResidualAllowance() public {
        this.doInitialize();

        uint256 stakeAmount = 0.1 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        address clonedProtocol = _cloneProtocolForTest(address(lidoProtocol));

        IERC20(mainnet.WETH).approve(clonedProtocol, 1);
        assertEq(IERC20(mainnet.WETH).allowance(address(this), clonedProtocol), 1);

        vm.prank(assetManagerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, stakeAmount);

        assertApproxEqAbs(IBittyV1Withdrawable(clonedProtocol).getBalance(mainnet.WETH), stakeAmount, 10);
    }

    // ============ Auto yield ============

    function test_SetAutoYieldingRevertNotOwner() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.expectRevert(_roleError(stranger, bytes32(0)));
        vm.prank(stranger);
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol)));
    }

    function test_SetAutoYieldingRevertAssetAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(address(0), address(aaveProtocol)));
    }

    /**
     * @dev There used to be a pair of tests here asserting that a staking protocol was not a valid
     *      supply route and vice versa. The vault no longer knows lending from staking - it routes to
     *      anything depositable - so both of those routes are legal now and the pair asserted a rule
     *      that no longer exists - test_AutoYieldSupplyOnDeposit and test_AutoYieldStakeOnDeposit
     *      already show both routes carrying a deposit. What still constrains a route is the guard: a
     *      protocol it has never registered cannot be yielded into, whatever it claims to be.
     */
    /// @dev A route to an unlisted protocol normally lists it as a side effect. Once the owner has
    ///      locked the protocol set that side effect is exactly what must not happen, so the route is
    ///      refused rather than quietly widening a list the owner sealed.
    function test_SetAutoYieldingRevertsWhenAddingProtocolsDisabled() public {
        this.doInitializeWithoutProtocols();
        vm.startPrank(ownerAddress);
        this.disableAddingProtocols();
        vm.expectRevert(AddingProtocolsDisabled.selector);
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol)));
        vm.stopPrank();
    }

    function test_SetAutoYieldingRevertUnregisteredProtocol() public {
        this.doInitialize();
        vm.expectRevert(NotRegistered.selector);
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, makeAddr("unregisteredProtocol")));
    }

    function test_SetAutoYieldings_batchSetsMultipleRoutes() public {
        this.doInitialize();
        AutoYield[] memory routes = new AutoYield[](2);
        routes[0] = AutoYield({asset: mainnet.WETH, protocol: address(aaveProtocol)});
        routes[1] = AutoYield({asset: WBTC, protocol: address(aaveProtocol)});

        vm.prank(ownerAddress);
        this.setAutoYieldings(routes);

        address p0 = _getAutoYieldingOne(mainnet.WETH);
        assertEq(p0, address(aaveProtocol));
        address p1 = _getAutoYieldingOne(WBTC);
        assertEq(p1, address(aaveProtocol));
    }

    // The merged setter: routes AND the keeper land in ONE transaction, and an
    /// The trigger is no longer a per-vault setting, so this only writes routes.
    function test_SetAutoYieldings_setsRoutes() public {
        this.doInitialize();
        AutoYield[] memory routes = new AutoYield[](1);
        routes[0] = AutoYield({asset: mainnet.WETH, protocol: address(aaveProtocol)});

        vm.prank(ownerAddress);
        this.setAutoYieldings(routes);

        address p = _getAutoYieldingOne(mainnet.WETH);
        assertEq(p, address(aaveProtocol));

        // An empty array is now simply a no-op rather than a trigger-only update.
        vm.prank(ownerAddress);
        this.setAutoYieldings(new AutoYield[](0));
        p = _getAutoYieldingOne(mainnet.WETH);
        assertEq(p, address(aaveProtocol), "routes untouched");
    }

    function test_SetAndGetAutoYielding() public {
        this.doInitialize();
        address protocol = _getAutoYieldingOne(mainnet.WETH);
        assertEq(protocol, address(0));

        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol)));
        protocol = _getAutoYieldingOne(mainnet.WETH);
        assertEq(protocol, address(aaveProtocol));

        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(0)));
        protocol = _getAutoYieldingOne(mainnet.WETH);
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
        this.autoYields(_one(mainnet.WETH));
    }

    function test_AutoYieldKeeperCanSweep() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol)));

        // The vault holds WETH (not from an ETH deposit) — the keeper sweeps it into the route.
        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(AUTO_YIELD_KEEPER_FOR_TEST);
        this.autoYields(_one(mainnet.WETH));

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        assertApproxEqAbs(IBittyV1Withdrawable(clonedProtocol).getBalance(mainnet.WETH), 1 ether, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    /// The owner can always sweep their own vault, so Auto Earn survives the keeper being down.
    function test_AutoYieldOwnerCanSweep() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol)));
        deal(mainnet.WETH, address(this), 1 ether);

        vm.prank(ownerAddress);
        this.autoYields(_one(mainnet.WETH));

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        assertApproxEqAbs(IBittyV1Withdrawable(clonedProtocol).getBalance(mainnet.WETH), 1 ether, 10);
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
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol)));

        _depositEth(1 ether);

        address clonedProtocol = this.getClonedProvider(address(aaveProtocol));
        assertApproxEqAbs(IBittyV1Withdrawable(clonedProtocol).getBalance(mainnet.WETH), 1 ether, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    function test_AutoYieldStakeOnDeposit() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol)));

        _depositEth(0.5 ether);

        assertApproxEqAbs(this.getBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 0.5 ether, 10);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0);
    }

    /**
     * @notice A deposit into a routed asset is now swept in FULL.
     * @dev This used to be a test about the per-asset minimal balance holding part of a deposit
     *      back. With that floor removed there is nothing to hold anything back: the deposit lands,
     *      the route fires, and the vault's liquid balance of that asset goes to zero.
     *
     *      Worth stating plainly because it is the trade-off the removal makes. A vault whose only
     *      stable coin is routed keeps no liquid balance at all, and a relayed call has nothing to
     *      pay its fee from — see Scaling's test_sweepingTheFeeCoinLeavesNothingToPayTheRelayer.
     */
    function test_DepositIntoARoutedAssetIsSweptInFull() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol)));

        _depositEth(1 ether);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 0, "nothing left liquid");
        assertApproxEqAbs(
            this.getBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 1 ether, 10, "all of it staked"
        );
    }

    /**
     * @notice Emptying the protocol list STOPS an auto-yield route; it does not resume it.
     * @dev The inversion this design change produces, and worth a test of its own. Under the old
     *      default an empty list meant "anything the guard allows", so removing the protocol handed
     *      the route back to the guard and the sweep kept running — a removal that widened. Now the
     *      list is the permission, so removing the protocol is what stops the sweep, and the funds
     *      simply stay in the vault.
     */
    function test_AutoYieldStopsWhenProtocolIsUnlisted() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol)));
        vm.prank(ownerAddress);
        this.updateProtocols(new address[](0), stakingProtocols);

        _depositEth(1 ether);
        assertEq(
            IERC20(mainnet.WETH).balanceOf(address(this)),
            1 ether,
            "not swept: the protocol is no longer listed, even though the guard still registers it"
        );
    }

    /// The direct way to stop a route, and the one that does not depend on list semantics.
    function test_AutoYieldClearedRouteIsSkipped() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol)));
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(0)));

        _depositEth(1 ether);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), 1 ether, "no route, nothing swept");
    }

    function test_AutoYieldSkippedForDeprecatedProtocol() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol)));
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        BittyV1Guard(guardAddress).deprecateProtocols(stakingProtocols);

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
        this.disableTradeUntilTimestamp(block.timestamp + 1 days);
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

    // ============ EIP-1271 signature validation (isValidSignature) ============

    function test_IsValidSignature_NoProtocolsReturnsFailure() public {
        this.doInitialize();
        assertTrue(this.isValidSignature(keccak256("order"), hex"1234") == bytes4(0xffffffff));
    }

    function test_IsValidSignature_MatchViaIntentClone() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _single(address(intent)));
        vm.stopPrank();

        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(intent)), new address[](0));

        assertTrue(this.isValidSignature(keccak256("order"), hex"abcd") == bytes4(0x1626ba7e));
    }

    /**
     * @notice A deprecated intent adapter must STILL validate signatures.
     * @dev Deprecation is exit-only, and validating is an exit. An order signed while the adapter was
     *      live still has to settle, and cancelling one still has to be provable — so validation
     *      cannot stop the moment the guard deprecates the protocol, or every pending order is
     *      stranded with no way to settle it and no way to cancel it.
     */
    function test_IsValidSignature_StillWorksAfterTheAdapterIsDeprecated() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _single(address(intent)));
        vm.stopPrank();

        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(intent)), new address[](0));
        assertTrue(this.isValidSignature(keccak256("order"), hex"abcd") == bytes4(0x1626ba7e), "live");

        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        BittyV1Guard(guardAddress).deprecateProtocols(_single(address(intent)));
        assertFalse(BittyV1Guard(guardAddress).isProtocolRegistered(address(intent)), "no longer active");

        assertTrue(
            this.isValidSignature(keccak256("order"), hex"abcd") == bytes4(0x1626ba7e),
            "a pending order must still settle after deprecation"
        );
    }

    // ============ Intent trade setup (composed from updateAssets / approveIntentRelayer) ============

    // Allow-listed either as a plain asset or a stablecoin — the Guard decides which set a token
    // lands in, and a restricted vault must treat both as "already added".
    function _hasAsset(address token) internal view returns (bool) {
        return this.isAssetAllowed(token);
    }

    // A first gasless trade on a RESTRICTED vault needs the buy asset allow-listed and the relayer
    // approved. On an unrestricted one only the approval is left, since the guard already permits
    // both the protocol and the asset.
    function test_IntentTradeSetup_onlyTouchesWhatIsRestricted() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        address relayer = makeAddr("vaultRelayer");
        intent.setEndpoints(makeAddr("settlement"), relayer);
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _single(address(intent)));
        vm.stopPrank();

        // A token the Guard knows but this vault has NOT added — exactly the
        // case a first buy of a new asset hits.
        MockERC20 newToken = new MockERC20("NEW", "NEW", 18);
        address newAsset = address(newToken);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddAssets(address(BittyV1Guard(guardAddress)), _single(newAsset));

        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(intent)), new address[](0));

        // Nothing is set up yet: no intent protocol, the asset isn't allow-listed.
        assertEq(
            vaultProtocols(guardAddress, address(this)).length, ENABLED_AT_INIT + 1, "the intent protocol is listed"
        );
        assertFalse(_hasAsset(newAsset), "asset not allow-listed yet");

        address[] memory assets = _single(newAsset);
        address[] memory approve = _single(mainnet.WETH);
        _prepareTrade(address(intent), assets, approve);

        // The trade adds no protocol of its own: the owner listed the intent protocol up front, and
        // preparing a trade must not quietly extend that list as a side effect.
        assertEq(
            vaultProtocols(guardAddress, address(this)).length, ENABLED_AT_INIT + 1, "the trade listed nothing further"
        );
        // The ASSET list is a different matter — this vault registered assets at init, so it IS
        // restricted for assets, and the buy token has to be added to it.
        assertTrue(_hasAsset(newAsset), "buy asset added to the restricted asset list");
        assertEq(
            IERC20(mainnet.WETH).allowance(address(this), relayer),
            type(uint256).max,
            "relayer approved for the sell token"
        );
    }

    // Called again before every order, so re-running must be a no-op rather
    // than reverting on the already-registered protocol/asset.
    /**
     * @dev Asserted against the calls a client composes for trade setup. Re-adding an asset already
     *      present is a no-op rather
     *      than a revert, which is what makes the composed sequence safe to repeat before every order.
     */
    function test_UpdateAssets_isIdempotent() public {
        this.doInitialize();
        vm.startPrank(ownerAddress);
        this.updateAssets(_single(WBTC), new address[](0));
        this.updateAssets(_single(WBTC), new address[](0));
        vm.stopPrank();
        assertTrue(_hasAsset(WBTC));
    }

    /**
     * @dev Once adding is locked, updateAssets reverts even with an EMPTY add list — the flag is
     *      checked before the loop, not per entry.
     *
     *      Worth pinning down, because a client composing trade setup must check what is missing
     *      before calling this:
     *      skip updateAssets entirely when nothing needs adding, or a locked vault can no longer set
     *      up a trade whose assets are all present already.
     */
    function test_UpdateAssets_revertsWhenAddingLockedEvenIfNothingToAdd() public {
        this.doInitialize();
        vm.startPrank(ownerAddress);
        this.updateAssets(_single(WBTC), new address[](0));
        this.disableAddingAssets();
        vm.expectRevert(AddingAssetsDisabled.selector);
        this.updateAssets(new address[](0), new address[](0));
        vm.stopPrank();
        assertTrue(_hasAsset(WBTC), "the earlier add still stands");
    }

    function test_UpdateAssets_revertsForNonOwner() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, bytes32(0)));
        this.updateAssets(_single(WBTC), new address[](0));
    }

    // ============ First supply / stake with no prior registration ============

    // A first lend into a protocol the vault hasn't enabled otherwise costs two
    // txs (owner registers it, manager supplies). For an owner who is also the
    // manager this does both at once.
    function test_SimpleSupply_registersProtocolAndSupplies() public {
        this.doInitializeWithoutProtocols();
        // The owner is also the asset manager — the single-user setup.
        _grantAssetManagerRole(ownerAddress);
        // Listing is the owner's call; using it is the manager's. Being both, they can do the two
        // in one transaction — which is what {Multicall} is for.
        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(aaveProtocol)), new address[](0));
        assertEq(vaultProtocols(guardAddress, address(this)).length, 1, "listed by the owner");

        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.prank(ownerAddress);
        this.deposit(address(aaveProtocol), mainnet.WETH, amount);

        assertEq(vaultProtocols(guardAddress, address(this)).length, 1, "supplying did not list anything further");
        assertApproxEqAbs(this.getBalances(_one(address(aaveProtocol)), _one(mainnet.WETH))[0], amount, 10);
    }

    function test_SimpleStake_registersProtocolAndStakes() public {
        this.doInitializeWithoutProtocols();
        _grantAssetManagerRole(ownerAddress);
        // Listing is the owner's call; using it is the manager's. Being both, they can do the two
        // in one transaction — which is what {Multicall} is for.
        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(lidoProtocol)), new address[](0));
        assertEq(vaultProtocols(guardAddress, address(this)).length, 1, "listed by the owner");

        uint256 amount = 0.1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.prank(ownerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, amount);

        assertEq(vaultProtocols(guardAddress, address(this)).length, 1, "supplying did not list anything further");
        assertGt(this.getBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 0);
    }

    // Already-registered protocol: no re-add (which would revert once adding is
    // locked), just the supply.
    function test_SimpleSupply_skipsRegistrationWhenAlreadyEnabled() public {
        this.doInitialize();
        _grantAssetManagerRole(ownerAddress);
        assertEq(vaultProtocols(guardAddress, address(this)).length, ENABLED_AT_INIT);

        vm.prank(ownerAddress);
        this.disableAddingProtocols();

        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.prank(ownerAddress);
        this.deposit(address(aaveProtocol), mainnet.WETH, amount);

        assertEq(vaultProtocols(guardAddress, address(this)).length, ENABLED_AT_INIT, "no extra registration");
    }

    // An owner who is NOT the asset manager can't move funds this way — they
    // keep the two-step path (register, then the manager supplies).
    function test_SimpleSupply_revertsWhenOwnerIsNotAssetManager() public {
        this.doInitialize();
        _grantAssetManagerRole(assetManagerAddress);

        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(ownerAddress);
        vm.expectRevert(NotAssetManager.selector);
        this.deposit(address(aaveProtocol), mainnet.WETH, 1 ether);
    }

    /**
     * @notice The asset manager cannot reach a protocol the OWNER has not listed.
     * @dev The reason `supply` and `stake` do not list protocols themselves. The manager is a
     *      delegated, often hot key; if using a protocol were enough to add it, the bound the owner
     *      set by listing would be one the manager could widen at will.
     */
    function test_AssetManagerMayNotStakeIntoAnUnlistedProtocol() public {
        this.doInitializeWithoutProtocols();
        deal(mainnet.WETH, address(this), 1 ether);
        assertEq(vaultProtocols(guardAddress, address(this)).length, 0, "nothing listed, so nothing usable");

        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidDepositableProtocol.selector);
        this.deposit(address(lidoProtocol), mainnet.WETH, 1 ether);

        assertEq(vaultProtocols(guardAddress, address(this)).length, 0, "and the attempt did not list it either");
    }

    // ---- Exiting a position: clear the route, then withdraw/unstake ----

    // Exiting an auto-yielded position is otherwise two txs (clear the route,
    // then withdraw) or an EIP-5792 batch the wallet may not support.
    function test_ClearRouteThenWithdraw() public {
        this.doInitialize();
        _grantAssetManagerRole(ownerAddress);

        uint256 amount = 1 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.startPrank(ownerAddress);
        this.deposit(address(aaveProtocol), mainnet.WETH, amount);
        // Route set: without clearing it the keeper would re-supply the funds.
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol)));
        address routed = _getAutoYieldingOne(mainnet.WETH);
        assertEq(routed, address(aaveProtocol), "route is set");

        _clearRoute(mainnet.WETH);
        this.withdraw(address(aaveProtocol), mainnet.WETH, 0.5 ether);
        vm.stopPrank();

        address after_ = _getAutoYieldingOne(mainnet.WETH);
        assertEq(after_, address(0), "route cleared");
        assertGe(IERC20(mainnet.WETH).balanceOf(address(this)), 0.5 ether, "funds back in the vault");
    }

    // clearRoute = false leaves the route alone (a partial exit that should keep
    // auto-yielding the rest).
    function test_SimpleWithdraw_keepsRouteWhenNotClearing() public {
        this.doInitialize();
        _grantAssetManagerRole(ownerAddress);

        deal(mainnet.WETH, address(this), 1 ether);
        vm.startPrank(ownerAddress);
        this.deposit(address(aaveProtocol), mainnet.WETH, 1 ether);
        this.setAutoYieldings(_route(mainnet.WETH, address(aaveProtocol)));
        this.withdraw(address(aaveProtocol), mainnet.WETH, 0.25 ether);
        vm.stopPrank();

        address routed = _getAutoYieldingOne(mainnet.WETH);
        assertEq(routed, address(aaveProtocol), "route untouched");
    }

    function test_ClearRouteThenUnstake() public {
        this.doInitialize();
        _grantAssetManagerRole(ownerAddress);

        uint256 amount = 0.2 ether;
        deal(mainnet.WETH, address(this), amount);
        vm.startPrank(ownerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, amount);
        this.setAutoYieldings(_route(mainnet.WETH, address(lidoProtocol)));

        _clearRoute(mainnet.WETH);
        this.withdraw(address(lidoProtocol), mainnet.WETH, 0.1 ether);
        vm.stopPrank();

        address routed = _getAutoYieldingOne(mainnet.WETH);
        assertEq(routed, address(0), "route cleared");
    }

    /**
     * @dev Exiting a position is asset-manager-gated, and clearing a route is owner-gated. They used
     *      to be fused in one owner-only call; keeping them apart is what makes each answerable to the
     *      right role.
     */
    function test_WithdrawIsAssetManagerGated() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(NotAssetManager.selector);
        this.withdraw(address(aaveProtocol), mainnet.WETH, 1);
    }

    function test_UnstakeIsAssetManagerGated() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(NotAssetManager.selector);
        this.withdraw(address(lidoProtocol), mainnet.WETH, 1);
    }

    function test_ClearRouteIsOwnerGated() public {
        this.doInitialize();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, bytes32(0)));
        _clearRoute(mainnet.WETH);
    }

    // End-to-end proof of why the buy leg must be allow-listed: a gasless order whose
    // BUY leg isn't allow-listed is refused by the vault's authorizer (CoW then
    // rejects the signature, which is the opaque "failed to buy" users hit).
    // Allow-listing the buy asset makes the very same order authorized.
    function test_AllowListingBuyAssetAuthorizesTheOrder() public {
        MockERC20 newToken = new MockERC20("BUYME", "BUYME", 18);
        MockIntentProtocol intent = new MockIntentProtocol();
        intent.setEndpoints(makeAddr("settlement"), makeAddr("vaultRelayer"));
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddAssets(address(BittyV1Guard(guardAddress)), _single(address(newToken)));
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _single(address(intent)));
        vm.stopPrank();

        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(intent)), new address[](0));
        deal(mainnet.WETH, address(this), 1 ether);

        // Before: the vault can't receive the token, so the order is refused.
        assertFalse(
            this.isOffchainOrderAuthorized(assetManagerAddress, mainnet.WETH, address(newToken), 0.5 ether),
            "unlisted buy token must be refused"
        );

        _prepareTrade(address(intent), _single(address(newToken)), _single(mainnet.WETH));

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
        this.deposit(address(lidoProtocol), mainnet.WETH, 1 ether);
    }

    /**
     * @dev The asset manager may supply directly, with nothing registered. That is the whole point of
     *      inheriting the guard: the old one-tx helper existed only because supplying into an
     *      unregistered protocol needed an owner to register it first.
     */
    /**
     * @notice The asset manager cannot reach a protocol the OWNER has not listed.
     * @dev The reason `supply` and `stake` do not list protocols themselves. The manager is a
     *      delegated, often hot key; if using a protocol were enough to add it, the bound the owner
     *      set by listing would be one the manager could widen at will.
     */
    function test_AssetManagerMayNotSupplyIntoAnUnlistedProtocol() public {
        this.doInitializeWithoutProtocols();
        deal(mainnet.WETH, address(this), 1 ether);
        assertEq(vaultProtocols(guardAddress, address(this)).length, 0, "nothing listed, so nothing usable");

        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidDepositableProtocol.selector);
        this.deposit(address(aaveProtocol), mainnet.WETH, 1 ether);

        assertEq(vaultProtocols(guardAddress, address(this)).length, 0, "and the attempt did not list it either");
    }

    function test_SimpleStake_skipsRegistrationWhenAlreadyEnabled() public {
        this.doInitialize();
        _grantAssetManagerRole(ownerAddress);
        assertEq(vaultProtocols(guardAddress, address(this)).length, ENABLED_AT_INIT);

        vm.prank(ownerAddress);
        this.disableAddingProtocols();

        deal(mainnet.WETH, address(this), 0.1 ether);
        vm.prank(ownerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, 0.1 ether);

        assertEq(vaultProtocols(guardAddress, address(this)).length, ENABLED_AT_INIT, "no extra registration");
        assertGt(this.getBalances(_one(address(lidoProtocol)), _one(mainnet.WETH))[0], 0);
    }

    // address(0) = "don't touch the intent protocol", so the call can be used to
    // only allow-list assets.
    function test_PrepareIntentTrade_zeroProtocolOnlyAddsAssets() public {
        MockERC20 newToken = new MockERC20("NEW2", "NEW2", 18);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddAssets(address(BittyV1Guard(guardAddress)), _single(address(newToken)));
        this.doInitialize();

        _prepareTrade(address(0), _single(address(newToken)), new address[](0));

        assertEq(
            vaultProtocols(guardAddress, address(this)).length, ENABLED_AT_INIT, "no protocol registered by the trade"
        );
        assertTrue(_hasAsset(address(newToken)), "asset still allow-listed");
    }

    // Mixed input: one asset already allow-listed, one not — only the missing
    // one is added (the filter that keeps a locked-adding vault working).
    function test_PrepareIntentTrade_addsOnlyMissingAssets() public {
        MockERC20 newToken = new MockERC20("NEW3", "NEW3", 18);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddAssets(address(BittyV1Guard(guardAddress)), _single(address(newToken)));
        this.doInitialize();

        // WETH is already on the vault; the mock token is not.
        assertTrue(_hasAsset(mainnet.WETH));
        assertFalse(_hasAsset(address(newToken)));

        _prepareTrade(address(0), _two(mainnet.WETH, address(newToken)), new address[](0));

        assertTrue(_hasAsset(mainnet.WETH), "existing asset untouched");
        assertTrue(_hasAsset(address(newToken)), "missing asset added");
    }

    // Nothing to do at all — must be a clean no-op rather than reverting.
    function test_PrepareIntentTrade_emptyArraysIsNoOp() public {
        this.doInitialize();
        _prepareTrade(address(0), new address[](0), new address[](0));
        assertEq(vaultProtocols(guardAddress, address(this)).length, ENABLED_AT_INIT);
    }

    // ============ AssetManagerLogic revert / branch coverage ============

    function test_WithdrawRevertInsufficientBalance() public {
        this.doInitialize();
        uint256 supplyAmount = 1 ether;
        deal(mainnet.WETH, address(this), supplyAmount);
        vm.prank(assetManagerAddress);
        this.deposit(address(aaveProtocol), mainnet.WETH, supplyAmount);

        vm.prank(assetManagerAddress);
        vm.expectRevert(InsufficientBalance.selector);
        this.withdraw(address(aaveProtocol), mainnet.WETH, supplyAmount * 2);
    }

    function test_StakeRevertAddressZero() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        vm.expectRevert(AddressZero.selector);
        this.deposit(address(lidoProtocol), address(0), 1 ether);
    }

    function test_UnstakeRevertAddressZero() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        vm.expectRevert(AddressZero.selector);
        this.withdraw(address(lidoProtocol), address(0), 1 ether);
    }

    function test_UnstakeRevertInsufficientBalance() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(assetManagerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, 1 ether);

        vm.prank(assetManagerAddress);
        vm.expectRevert(InsufficientBalance.selector);
        this.withdraw(address(lidoProtocol), mainnet.WETH, 100 ether);
    }

    function test_GetStakedBalanceRevertAddressZero() public {
        this.doInitialize();
        vm.expectRevert(AddressZero.selector);
        this.getBalances(_one(address(lidoProtocol)), _one(address(0)));
    }

    function test_ClaimWithdrawalsRevertInvalidWithdrawableProtocol() public {
        this.doInitialize();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidWithdrawableProtocol.selector);
        this.claimWithdrawals(address(lidoProtocol), ids);
    }

    function test_ClaimWithdrawalScalarRevertInvalidWithdrawableProtocol() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidWithdrawableProtocol.selector);
        this.claimWithdrawal(address(lidoProtocol), 1);
    }

    function test_ClaimWithdrawalScalarSuccess() public {
        this.doInitialize();
        uint256 stakeAmount = 0.1 ether;
        uint256 unstakeAmount = 0.05 ether;
        deal(mainnet.WETH, address(this), stakeAmount);

        vm.startPrank(assetManagerAddress);
        this.deposit(address(lidoProtocol), mainnet.WETH, stakeAmount);
        this.withdraw(address(lidoProtocol), mainnet.WETH, unstakeAmount);
        vm.stopPrank();

        uint256[] memory requestIds = this.getPendingWithdrawalIds(address(lidoProtocol));
        assertEq(requestIds.length, 1);

        vm.prank(assetManagerAddress);
        this.claimWithdrawal(address(lidoProtocol), requestIds[0]);
        // Lido withdrawals are not finalized immediately on a mainnet fork.
        assertEq(this.getPendingWithdrawalIds(address(lidoProtocol)).length, 1);
    }

    function test_ClaimWithdrawalScalarRevertOnlyAssetManager() public {
        this.doInitialize();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotAssetManager.selector);
        this.claimWithdrawal(address(lidoProtocol), 1);
    }

    function test_AddStakingProtocolsRevertNotRegistered() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        vm.expectRevert(NotRegistered.selector);
        this.updateProtocols(_single(makeAddr("unregisteredStaking")), new address[](0));
    }

    function test_AddLiquidityRevertInvalidAMMProtocol() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidAMMProtocol.selector);
        this.addLiquidity(makeAddr("unregisteredAMM"), mainnet.WETH, 0, mainnet.USDT, 0, "");
    }

    function test_disableTradeUntilTimestampZeroIsNoop() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        this.disableTradeUntilTimestamp(0);
    }

    function test_ApproveIntentRelayerRevertInvalidIntentProtocol() public {
        this.doInitialize();
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidIntentProtocol.selector);
        this.approveIntentRelayer(makeAddr("unregisteredIntent"), mainnet.WETH);
    }

    function test_ApproveIntentRelayerRevertDeprecated() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _single(address(intent)));
        vm.stopPrank();

        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(intent)), new address[](0));

        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        BittyV1Guard(guardAddress).deprecateProtocols(_single(address(intent)));

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
        assertEq(vaultProtocols(guardAddress, address(this)).length, ENABLED_AT_INIT);
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
        assertEq(effectiveAssetManager(address(this)), assetManagerAddress);
        // setAssetManager(address(0), 0) clears it — the former removeAssetManager.
        vm.prank(ownerAddress);
        this.setAssetManager(address(0), 0);
        assertEq(effectiveAssetManager(address(this)), address(0));
    }

    // ============ Asset manager expiry ============

    function test_ExpiringGrant_TradesUntilTheDeadlineThenStops() public {
        this.doInitialize();
        uint64 expiresAt = uint64(block.timestamp + 7 days);
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, expiresAt);

        assertEq(effectiveAssetManager(address(this)), assetManagerAddress, "live while the grant stands");

        vm.warp(expiresAt);
        assertEq(effectiveAssetManager(address(this)), assetManagerAddress, "still live ON the deadline second");

        vm.warp(expiresAt + 1);
        assertEq(effectiveAssetManager(address(this)), address(0), "lapses without anyone sending a transaction");

        vm.prank(assetManagerAddress);
        vm.expectRevert(AssetManagerExpired.selector);
        this.deposit(address(aaveProtocol), mainnet.WETH, 1 ether);
    }

    /// A lapsed grant must read as "renew me", not as "wrong key".
    function test_ExpiredManagerAndStrangerGetDifferentErrors() public {
        this.doInitialize();
        uint64 expiresAt = uint64(block.timestamp + 1 days);
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, expiresAt);
        vm.warp(expiresAt + 1);

        vm.prank(assetManagerAddress);
        vm.expectRevert(AssetManagerExpired.selector);
        this.deposit(address(lidoProtocol), mainnet.WETH, 1 ether);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotAssetManager.selector);
        this.deposit(address(lidoProtocol), mainnet.WETH, 1 ether);
    }

    /// The gasless CoW path must lapse with everything else, or an expired key could still settle.
    function test_ExpiredManagerCannotAuthorizeOffchainOrders() public {
        this.doInitialize();
        deal(mainnet.WETH, address(this), 1 ether);
        uint64 expiresAt = uint64(block.timestamp + 1 days);
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, expiresAt);

        // Asserted true first, so the false below is the expiry biting rather than some unrelated
        // leg of the check (buy token, balance, paused trading) failing all along.
        assertTrue(this.isOffchainManager(assetManagerAddress), "manager recognised while live");
        assertTrue(
            this.isOffchainOrderAuthorized(assetManagerAddress, mainnet.WETH, WBTC, 0.5 ether),
            "order authorized while the grant stands"
        );

        vm.warp(expiresAt + 1);
        assertFalse(this.isOffchainManager(assetManagerAddress), "cancellation authority lapses too");
        assertFalse(
            this.isOffchainOrderAuthorized(assetManagerAddress, mainnet.WETH, WBTC, 0.5 ether),
            "no solver can settle an order signed by a lapsed key"
        );
    }

    function test_RenewingExtendsAndShorteningTakesEffectImmediately() public {
        this.doInitialize();
        uint64 first = uint64(block.timestamp + 1 days);
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, first);

        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, first + 30 days);
        vm.warp(first + 1);
        assertEq(effectiveAssetManager(address(this)), assetManagerAddress, "renewal carried it past the old deadline");

        uint64 soon = uint64(block.timestamp + 1 hours);
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, soon);
        vm.warp(soon + 1);
        assertEq(effectiveAssetManager(address(this)), address(0), "shortening bites without a timelock");
    }

    function test_ZeroExpiryNeverLapses() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, 0);

        (address manager, uint64 expiresAt,,) = this.getAssetManagerSettings();
        assertEq(manager, assetManagerAddress);
        assertEq(expiresAt, 0, "0 means never");

        vm.warp(block.timestamp + 3650 days);
        assertEq(effectiveAssetManager(address(this)), assetManagerAddress, "an unset expiry never arrives");
    }

    /// Storage keeps the lapsed grant so a UI can say who it was; only authority is withdrawn.
    function test_SettingsStillReportTheManagerAfterExpiry() public {
        this.doInitialize();
        uint64 expiresAt = uint64(block.timestamp + 1 days);
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, expiresAt);
        vm.warp(expiresAt + 1);

        (address manager, uint64 storedExpiry,,) = this.getAssetManagerSettings();
        assertEq(manager, assetManagerAddress, "raw read is unfiltered");
        assertEq(storedExpiry, expiresAt);
        assertEq(effectiveAssetManager(address(this)), address(0), "effective read is not");
    }

    function test_ExpiryInThePastIsRejected() public {
        this.doInitialize();
        vm.warp(1000);
        vm.prank(ownerAddress);
        vm.expectRevert(AssetManagerExpiryInPast.selector);
        this.setAssetManager(assetManagerAddress, uint64(block.timestamp));

        vm.prank(ownerAddress);
        vm.expectRevert(AssetManagerExpiryInPast.selector);
        this.setAssetManager(assetManagerAddress, uint64(block.timestamp - 1));
    }

    function test_SetAssetManagerIsOwnerOnly() public {
        this.doInitialize();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        this.setAssetManager(makeAddr("newManager"), uint64(block.timestamp + 1 days));
    }

    function test_PassingZeroClearsAPreviousExpiry() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, uint64(block.timestamp + 1 days));

        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, 0);

        (, uint64 expiresAt,,) = this.getAssetManagerSettings();
        assertEq(expiresAt, 0, "re-setting with 0 must clear the previous deadline, not inherit it");
    }

    function test_SetAssetManagerEmitsWithTheExpiry() public {
        this.doInitialize();
        uint64 expiresAt = uint64(block.timestamp + 5 days);
        address newManager = makeAddr("newManager");
        vm.prank(ownerAddress);
        vm.expectEmit(true, false, false, true);
        emit IBittyV1Owner.AssetManagerSet(newManager, expiresAt);
        this.setAssetManager(newManager, expiresAt);
    }

    function test_AddAMMProtocolsEmitsAndKeepsRegistered() public {
        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(uniswapV3Protocol)), new address[](0));
        // Already listed by doInitialize, so re-adding it changes nothing.
        assertEq(vaultProtocols(guardAddress, address(this)).length, ENABLED_AT_INIT);
    }

    function test_RemoveIntentProtocols() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _single(address(intent)));
        vm.stopPrank();

        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(intent)), new address[](0));
        assertEq(vaultProtocols(guardAddress, address(this)).length, ENABLED_AT_INIT + 1);

        vm.prank(ownerAddress);
        this.updateProtocols(new address[](0), _single(address(intent)));
        assertEq(vaultProtocols(guardAddress, address(this)).length, ENABLED_AT_INIT);
    }

    function test_ApproveIntentRelayerSuccess() public {
        MockIntentProtocol intent = new MockIntentProtocol();
        address relayer = makeAddr("relayer");
        intent.setEndpoints(makeAddr("settlement"), relayer);
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _single(address(intent)));
        vm.stopPrank();

        this.doInitialize();
        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(intent)), new address[](0));

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
        this.batchSend(recipients, sendAssets, amounts, stakingProtos, stakingAmounts);
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

    /**
     * @dev Trade setup, composed from the calls a client makes. Deliberately a test helper rather
     *      than a contract function: on an unrestricted vault the first two steps are no-ops, and the
     *      approval only needs doing when the allowance is actually short — which a client can see
     *      and the contract cannot.
     */

    /// @dev Has this vault narrowed `categoryId`? Derived, because the vault no longer answers it.
    function _hasProtocolOfCategory(uint8 categoryId) internal view returns (bool) {
        address[] memory listed = vaultProtocols(guardAddress, address(this));
        for (uint256 i; i < listed.length; ++i) {
            if (BittyV1Guard(guardAddress).protocolCategory(listed[i]) == categoryId) return true;
        }
        return false;
    }

    function _prepareTrade(address intentProtocol, address[] memory assets, address[] memory approveTokens) internal {
        // Was "getIntentProtocols().length > 0". The vault's list is flat now, so a client asks the
        // same question by reading the list and looking up each entry's category on the guard —
        // which is exactly what this helper does, so the awkwardness (if any) shows up here.
        if (intentProtocol != address(0) && _hasProtocolOfCategory(INTENT_ID)) {
            vm.prank(ownerAddress);
            this.updateProtocols(_single(intentProtocol), new address[](0));
        }
        uint256 missing;
        for (uint256 i; i < assets.length; ++i) {
            if (!_hasAsset(assets[i])) ++missing;
        }
        if (missing > 0) {
            address[] memory toAdd = new address[](missing);
            uint256 j;
            for (uint256 i; i < assets.length; ++i) {
                if (!_hasAsset(assets[i])) toAdd[j++] = assets[i];
            }
            vm.prank(ownerAddress);
            this.updateAssets(toAdd, new address[](0));
        }
        for (uint256 i; i < approveTokens.length; ++i) {
            vm.prank(_assetManager.assetManager);
            this.approveIntentRelayer(intentProtocol, approveTokens[i]);
        }
    }

    /**
     * @dev Clearing a route before exiting a position. Clearing a route is an OWNER
     *      decision and exiting a position is the asset manager's, so composing them here keeps the
     *      two roles visible instead of blurring them behind one owner-gated call. Call inside an
     *      owner prank.
     */
    function _clearRoute(address assetAddress) internal {
        AutoYield[] memory routes = new AutoYield[](1);
        routes[0] = AutoYield({asset: assetAddress, protocol: address(0)});
        this.setAutoYieldings(routes);
    }

    /**
     * @notice Once a category IS narrowed, a protocol outside the list is refused — even though the
     *         guard registered it and the flat list is non-empty for other reasons.
     * @dev The other half of the same invariant: the per-category count has to gate the right way in
     *      both directions, or narrowing would be decorative.
     */
    function test_NarrowingStakingRefusesAnUnlistedStakingProtocol() public {
        this.doInitializeWithoutProtocols();

        // Register a SECOND staking protocol with the guard, but narrow the vault to Lido only.
        MockStakingProtocol other = new MockStakingProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _single(address(other)));
        vm.stopPrank();

        vm.prank(ownerAddress);
        this.updateProtocols(_single(address(lidoProtocol)), new address[](0));

        deal(mainnet.WETH, address(this), 0.1 ether);
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidDepositableProtocol.selector);
        this.deposit(address(other), mainnet.WETH, 0.1 ether);
    }

    function _listed(address[] memory list, address a) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }

    // ============ Asset-manager timelock ============
    //
    // Installing a manager waits out the vault's changeTimelock — the SAME delay the payment risk
    // controls use. Revoking and shortening do not, because those are the moments an owner must not
    // be made to wait. Activation does not either, since it grants the owner nothing new.

    function _setChangeTimelock(uint64 delay) internal {
        vm.prank(ownerAddress);
        this.updatePaymentRisk(
            IBittyV1Owner.PaymentRisk({
                newPaymentProtection: 0, maxSendValue: 0, maxSendInterval: 0, changeTimelock: delay
            })
        );
    }

    function test_ActivationGrantsTheOwnerImmediately() public {
        // initialize() only — doInitialize would install its own manager afterwards and hide this.
        this.initialize(ownerAddress, mainnet.WETH, address(0), 0);
        // No delay served, even though the vault has one: the owner as their own manager can already
        // send every transaction the grant would allow.
        assertEq(effectiveAssetManager(address(this)), ownerAddress, "owner is manager from birth");
        (,, address pending, uint64 pendingAt) = this.getAssetManagerSettings();
        assertEq(pending, address(0), "nothing scheduled by activation");
        assertEq(pendingAt, 0);
    }

    function test_InstallingAManagerWaitsOutTheChangeTimelock() public {
        this.doInitialize();
        _setChangeTimelock(3 days);

        address hot = makeAddr("hotKey");
        vm.prank(ownerAddress);
        this.setAssetManager(hot, 0);

        // Scheduled, not granted: the old manager still holds authority for the whole delay.
        assertEq(effectiveAssetManager(address(this)), assetManagerAddress, "not yet in force");
        (,, address pending, uint64 pendingAt) = this.getAssetManagerSettings();
        assertEq(pending, hot, "scheduled, and visible to the owner");
        assertEq(pendingAt, uint64(block.timestamp) + 3 days);

        vm.warp(pendingAt - 1);
        assertEq(effectiveAssetManager(address(this)), assetManagerAddress, "still not, one second before");

        vm.warp(pendingAt);
        assertEq(effectiveAssetManager(address(this)), hot, "in force, with nobody having settled it");
    }

    /// @dev {effectiveAssetManager} reads a matured grant through without writing it. The write is
    ///      what the NEXT setAssetManager does before it schedules anything, so the grant it is about
    ///      to replace is the matured one rather than the stale slot it superseded.
    function test_AMaturedInstallIsPromotedByTheNextSet() public {
        this.doInitialize();
        _setChangeTimelock(3 days);

        address first = makeAddr("firstHotKey");
        vm.prank(ownerAddress);
        this.setAssetManager(first, 0);
        (,,, uint64 pendingAt) = this.getAssetManagerSettings();
        vm.warp(pendingAt);

        address second = makeAddr("secondHotKey");
        vm.prank(ownerAddress);
        this.setAssetManager(second, 0);

        (address manager,, address pending, uint64 nextAt) = this.getAssetManagerSettings();
        assertEq(manager, first, "the matured grant was written to the live slot");
        assertEq(pending, second, "and the new one took the pending slot it vacated");
        assertEq(nextAt, uint64(block.timestamp) + 3 days, "serving its own full delay");
        assertEq(effectiveAssetManager(address(this)), first, "the promoted manager holds authority");
    }

    /// @dev The point of the delay: a stolen owner key cannot install a manager and trade at once.
    function test_ScheduledManagerCannotTradeBeforeItMatures() public {
        this.doInitialize();
        _setChangeTimelock(3 days);

        address hot = makeAddr("attackerKey");
        vm.prank(ownerAddress);
        this.setAssetManager(hot, 0);

        deal(mainnet.WETH, address(this), 1 ether);
        vm.prank(hot);
        vm.expectRevert();
        this.deposit(address(aaveProtocol), mainnet.WETH, 1 ether);
    }

    function test_RevokingIsImmediateAndCancelsAScheduledInstall() public {
        this.doInitialize();
        _setChangeTimelock(3 days);

        address hot = makeAddr("hotKey2");
        vm.prank(ownerAddress);
        this.setAssetManager(hot, 0);

        // The answer to noticing a scheduled install you did not make.
        vm.prank(ownerAddress);
        this.setAssetManager(address(0), 0);

        assertEq(effectiveAssetManager(address(this)), address(0), "revoked at once");
        (,, address pending, uint64 pendingAt) = this.getAssetManagerSettings();
        assertEq(pending, address(0), "and the schedule went with it");
        assertEq(pendingAt, 0);

        vm.warp(block.timestamp + 30 days);
        assertEq(effectiveAssetManager(address(this)), address(0), "it cannot mature later either");
    }

    function test_ShorteningTheCurrentGrantIsImmediate() public {
        this.doInitialize();
        _setChangeTimelock(3 days);

        uint64 soon = uint64(block.timestamp + 1 hours);
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, soon);

        (address manager, uint64 expiresAt,, uint64 pendingAt) = this.getAssetManagerSettings();
        assertEq(manager, assetManagerAddress);
        assertEq(expiresAt, soon, "the shorter expiry applied without waiting");
        assertEq(pendingAt, 0, "nothing scheduled");

        vm.warp(soon + 1);
        assertEq(effectiveAssetManager(address(this)), address(0), "and it lapses when it said it would");
    }

    /// @dev EXTENDING is loosening, so it waits — otherwise "shortening" would be a way in.
    function test_ExtendingTheCurrentGrantWaits() public {
        this.doInitialize();
        _setChangeTimelock(3 days);

        uint64 soon = uint64(block.timestamp + 1 hours);
        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, soon);

        vm.prank(ownerAddress);
        this.setAssetManager(assetManagerAddress, uint64(block.timestamp + 365 days));

        (, uint64 expiresAt,, uint64 pendingAt) = this.getAssetManagerSettings();
        assertEq(expiresAt, soon, "the live grant still ends when it did");
        assertGt(pendingAt, 0, "the extension is scheduled");
    }

    /// @dev A vault with no delay configured applies the change at once — there is nothing to wait.
    function test_NoTimelockAppliesImmediately() public {
        this.doInitialize();
        address hot = makeAddr("hotKey3");
        vm.prank(ownerAddress);
        this.setAssetManager(hot, 0);
        assertEq(effectiveAssetManager(address(this)), hot, "no delay configured, no delay served");
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
