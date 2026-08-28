// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {guardAddAssets, guardAddStableCoins, guardAddProtocols} from "../helpers/GuardRegister.sol";
import {GUARD_DEPLOYER} from "../helpers/GuardDeployer.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {IBittyV1Vault, ScheduledPaymentNotStartYet, AutoYield} from "../../src/interfaces/IBittyV1Vault.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";
import {mainnet} from "protocol-contracts/script/addresses.sol";

/**
 * @notice Mainnet fork: parents deploy a WBTC/WETH kids vault via the factory,
 * schedule gifts at age 18, renounce admin, and kids claim through gift wallets.
 */
contract VaultForKidsForkTest is Test {
    /**
     * The address that will actually be msg.sender for the next call, honouring an active prank.
     */
    function _self() internal view returns (address) {
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        return mode == VmSafe.CallerMode.None ? address(this) : sender;
    }

    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address internal ALICE_ADDRESS = makeAddr("alice");
    uint256 internal constant EIGHTEEN_TIMESTAMP = 2348651757;
    uint256 internal constant PAY_AMOUNT_WBTC = 1e6;
    uint256 internal constant PAY_AMOUNT_WETH = 0.1 ether;
    uint256 internal constant PAY_INTERVAL = 30 days;
    uint8 internal constant PAY_COUNT = 120;

    BittyV1VaultFactory public factory;
    BittyV1Vault public vaultImpl;
    BittyV1Vault public vault;
    BittyV1Guard public guard;

    address[] internal assetAddresses;
    AutoYield[] internal noYield;

    address public parentOwner;

    // Single-item wrapper.
    function _addScheduledPayment(IBittyV1Vault.ScheduledPayment memory sp) internal returns (uint256) {
        IBittyV1Vault.ScheduledPayment[] memory arr = new IBittyV1Vault.ScheduledPayment[](1);
        arr[0] = sp;
        uint256[] memory ids = new uint256[](1);
        ids[0] = vault.addScheduledPayment(arr[0]);
        return ids.length == 0 ? 0 : ids[0];
    }

    function _u1(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _a1(address v) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = v;
    }

    function setUp() public {
        // Pinned. Unpinned, this follows mainnet HEAD — and since the guard was deployed to
        // BITTY_GUARD at block 25830629 the fork now carries the real one, pre-populated with
        // assets, so setUp could not install its own and the fixtures no longer matched.
        // A pin below that block also makes these tests deterministic, which they were not.
        vm.createSelectFork("mainnet", 25829629);

        assetAddresses = new address[](2);
        assetAddresses[0] = WBTC;
        assetAddresses[1] = mainnet.WETH;

        // On a mainnet fork BITTY_GUARD now holds the REAL deployed guard, and
        // AccessControlDefaultAdminRules refuses to install a second admin over its storage —
        // so re-deploying reverts. Deploy only when the fork block predates the deployment.
        if (BITTY_GUARD.code.length == 0) {
            vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
            deployCodeTo("BittyV1Guard.sol:BittyV1Guard", BITTY_GUARD);
            vm.stopPrank();
        }
        guard = BittyV1Guard(BITTY_GUARD);
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guard.grantRole(guard.ASSET_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.PROTOCOL_MANAGER_ROLE(), tx.origin);
        guardAddAssets(address(guard), assetAddresses);
        vm.stopPrank();

        vaultImpl = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()), address(0xA07E1D));
        BittyV1VaultDeFiFacet defiFacet = new BittyV1VaultDeFiFacet();
        factory = new BittyV1VaultFactory();
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(address(vaultImpl), mainnet.WETH);

        parentOwner = address(this);
    }

    function _deployKidsVaultViaFactory() internal {
        address expected = factory.vaultAddress(parentOwner);
        factory.activateVault();
        address vaultAddr = factory.vaultAddress(parentOwner);

        assertEq(vaultAddr, expected);
        vault = BittyV1Vault(payable(vaultAddr));
    }

    function _makeScheduledPayment(
        address scheduledPaymentAddress_,
        address assetAddress_,
        uint256 amount_,
        uint256 startTimestamp_
    ) internal pure returns (IBittyV1Vault.ScheduledPayment memory) {
        return IBittyV1Vault.ScheduledPayment({
            recipient: scheduledPaymentAddress_,
            trigger: address(0),
            assetAddress: assetAddress_,
            amount: amount_,
            remainingPaymentCount: type(uint256).max,
            startTimestamp: startTimestamp_,
            paymentInterval: PAY_INTERVAL,
            isImmutable: true,
            payWithInsufficientBalance: true
        });
    }

    /**
     * @dev Steps from file comments:
     * 1. Vault limited to WBTC and WETH (deployed through BittyV1VaultFactory on mainnet fork).
     * 2. Two scheduledPayments pay kids at their 18th birthday.
     * 3. Parent renounces admin (no on-chain owner).
     * 4. After the 18th birthday, kids redirect payouts to a new address.
     */
    function test_vaultForKids_fullLifecycle() public {
        // Step 1: factory deploys a vault with only WBTC and WETH
        _deployKidsVaultViaFactory();
        assertTrue(vault.owner() == parentOwner);

        // Step 2: scheduled gifts at 18th birthday
        IBittyV1Vault.ScheduledPayment memory wbtcScheduledPayment =
            _makeScheduledPayment(ALICE_ADDRESS, WBTC, PAY_AMOUNT_WBTC, EIGHTEEN_TIMESTAMP);
        IBittyV1Vault.ScheduledPayment memory wethScheduledPayment =
            _makeScheduledPayment(ALICE_ADDRESS, mainnet.WETH, PAY_AMOUNT_WETH, EIGHTEEN_TIMESTAMP);

        uint256 wbtcId = _addScheduledPayment(wbtcScheduledPayment);
        uint256 wethId = _addScheduledPayment(wethScheduledPayment);

        uint256 totalWBTCBalance = PAY_COUNT * PAY_AMOUNT_WBTC + 1e5;
        uint256 totalWETHBalance = PAY_COUNT * PAY_AMOUNT_WETH + 0.01 ether;
        deal(WBTC, address(vault), totalWBTCBalance);
        deal(mainnet.WETH, address(vault), totalWETHBalance);

        vm.expectRevert(ScheduledPaymentNotStartYet.selector);
        vault.payScheduleds(_u1(wbtcId), new address[](0), new uint256[](0));

        // Step 3: parent gives up vault admin in one atomic renounceVaultOwnership().
        // The immutable gifts must be locked (past their lock window, capped at
        // 7 days) to survive as the rescue path, so let that window pass first.
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(parentOwner);
        vault.renounceVaultOwnership(wbtcId);
        assertFalse(vault.owner() == parentOwner);

        vm.expectRevert();
        _addScheduledPayment(wbtcScheduledPayment);

        // Step 4: after age 18, the scheduled gifts pay out to the kids' configured addresses.
        vm.warp(EIGHTEEN_TIMESTAMP);

        vault.payScheduleds(_u1(wbtcId), new address[](0), new uint256[](0));
        vault.payScheduleds(_u1(wethId), new address[](0), new uint256[](0));

        for (uint256 i = 1; i <= PAY_COUNT; i++) {
            vm.warp(EIGHTEEN_TIMESTAMP + i * PAY_INTERVAL);
            vault.payScheduleds(_u1(wbtcId), new address[](0), new uint256[](0));
            vault.payScheduleds(_u1(wethId), new address[](0), new uint256[](0));
        }
        assertEq(IERC20(WBTC).balanceOf(ALICE_ADDRESS), totalWBTCBalance);
        assertEq(IERC20(mainnet.WETH).balanceOf(ALICE_ADDRESS), totalWETHBalance);
        assertEq(IERC20(WBTC).balanceOf(address(vault)), 0);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);
    }
}
