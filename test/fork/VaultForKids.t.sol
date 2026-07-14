// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {
    IBittyV1Vault,
    ReceiverNotStartYet,
    OnlyReceiver,
    AddingAssetsDisabled
} from "../../src/interfaces/IBittyV1Vault.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {mainnet} from "protocol-contracts/script/addresses.sol";

/// @notice Mainnet fork: parents deploy a WBTC/WETH kids vault via the factory,
/// schedule gifts at age 18, renounce admin, and kids claim through gift wallets.
contract VaultForKidsForkTest is Test {
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address internal ALICE_ADDRESS = makeAddr("alice");
    uint256 internal constant EIGHTEEN_TIMESTAMP = 2348651757;
    uint256 internal constant PAY_AMOUNT_WBTC = 1e6;
    uint256 internal constant PAY_AMOUNT_WETH = 0.1 ether;
    uint256 internal constant PAY_INTERVAL = 30 days;
    uint8 internal constant PAY_COUNT = 120;
    string internal constant VAULT_NAME = "Treasury for Alice";
    string internal constant RECEIVER_NAME_WBTC = "WBTC for Alice";
    string internal constant RECEIVER_NAME_WETH = "WETH for Alice";

    BittyV1VaultFactory public factory;
    BittyV1Vault public vaultImpl;
    BittyV1Vault public vault;
    BittyV1Guard public guard;

    address[] internal assetAddresses;

    address public parentOwner;

    function setUp() public {
        vm.createSelectFork("mainnet");

        assetAddresses = new address[](2);
        assetAddresses[0] = WBTC;
        assetAddresses[1] = mainnet.WETH;

        guard = new BittyV1Guard();
        vm.startPrank(tx.origin);
        guard.grantRole(guard.ASSET_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.STABLE_COIN_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.LENDING_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.STAKING_MANAGER_ROLE(), tx.origin);
        guard.grantRole(guard.AMM_MANAGER_ROLE(), tx.origin);
        guard.addAssets(assetAddresses);
        vm.stopPrank();

        vaultImpl = new BittyV1Vault();
        factory = new BittyV1VaultFactory();
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(address(vaultImpl), address(guard), mainnet.WETH);

        parentOwner = address(this);
    }

    function _deployKidsVaultViaFactory() internal {
        address expected = factory.computeVaultAddress(parentOwner, VAULT_NAME);
        address vaultAddr = factory.deployVaultWithSelected(
            VAULT_NAME,
            new address[](0),
            assetAddresses,
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );

        assertEq(vaultAddr, expected);
        vault = BittyV1Vault(payable(vaultAddr));
    }

    function _makeReceiver(address receiverAddress_, address assetAddress_, uint256 amount_, uint256 startTimestamp_)
        internal
        pure
        returns (IBittyV1Vault.Receiver memory)
    {
        return IBittyV1Vault.Receiver({
            receiverAddress: receiverAddress_,
            trigger: address(0),
            assetAddress: assetAddress_,
            amount: amount_,
            paymentCount: type(uint8).max,
            startTimestamp: startTimestamp_,
            paymentInterval: PAY_INTERVAL,
            isImmutable: false,
            payWithInsufficientBalance: true
        });
    }

    /// @dev Steps from file comments:
    /// 1. Vault limited to WBTC and WETH (deployed through BittyV1VaultFactory on mainnet fork).
    /// 2. Two receivers pay kids at their 18th birthday.
    /// 3. Parent renounces admin (no on-chain owner).
    /// 4. After the 18th birthday, kids redirect payouts to a new address.
    function test_vaultForKids_fullLifecycle() public {
        // Step 1: factory deploys a vault with only WBTC and WETH
        _deployKidsVaultViaFactory();
        assertEq(vault.vaultName(), VAULT_NAME);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), parentOwner));

        // Step 2: scheduled gifts at 18th birthday
        IBittyV1Vault.Receiver memory wbtcReceiver =
            _makeReceiver(ALICE_ADDRESS, WBTC, PAY_AMOUNT_WBTC, EIGHTEEN_TIMESTAMP);
        IBittyV1Vault.Receiver memory wethReceiver =
            _makeReceiver(ALICE_ADDRESS, mainnet.WETH, PAY_AMOUNT_WETH, EIGHTEEN_TIMESTAMP);

        vault.addReceiver(RECEIVER_NAME_WBTC, wbtcReceiver);
        vault.addReceiver(RECEIVER_NAME_WETH, wethReceiver);

        uint256 totalWBTCBalance = PAY_COUNT * PAY_AMOUNT_WBTC + 1e5;
        uint256 totalWETHBalance = PAY_COUNT * PAY_AMOUNT_WETH + 0.01 ether;
        deal(WBTC, address(vault), totalWBTCBalance);
        deal(mainnet.WETH, address(vault), totalWETHBalance);

        vm.expectRevert(ReceiverNotStartYet.selector);
        vault.payReceiver(RECEIVER_NAME_WBTC);

        // Step 3: parent gives up vault admin — no account holds DEFAULT_ADMIN_ROLE afterward
        vm.startPrank(parentOwner);
        vault.beginDefaultAdminTransfer(address(0));
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(parentOwner);
        vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), parentOwner);
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), parentOwner));

        vm.expectRevert();
        vault.addReceiver(RECEIVER_NAME_WBTC, wbtcReceiver);

        // Step 4: after age 18, kids move gifts to personal wallets and claim
        vm.warp(EIGHTEEN_TIMESTAMP);

        vm.prank(ALICE_ADDRESS);
        address newAddress = makeAddr("newAddress");
        vault.changeReceiverAddress(RECEIVER_NAME_WBTC, newAddress);
        vm.prank(ALICE_ADDRESS);
        vault.changeReceiverAddress(RECEIVER_NAME_WETH, newAddress);

        vault.payReceiver(RECEIVER_NAME_WBTC);
        vault.payReceiver(RECEIVER_NAME_WETH);

        for (uint256 i = 1; i <= PAY_COUNT; i++) {
            vm.warp(EIGHTEEN_TIMESTAMP + i * PAY_INTERVAL);
            vm.prank(ALICE_ADDRESS);
            vault.payReceiver(RECEIVER_NAME_WBTC);
            vm.prank(ALICE_ADDRESS);
            vault.payReceiver(RECEIVER_NAME_WETH);
        }
        assertEq(IERC20(WBTC).balanceOf(newAddress), totalWBTCBalance);
        assertEq(IERC20(mainnet.WETH).balanceOf(newAddress), totalWETHBalance);
        assertEq(IERC20(WBTC).balanceOf(address(vault)), 0);
        assertEq(IERC20(mainnet.WETH).balanceOf(address(vault)), 0);
    }
}
