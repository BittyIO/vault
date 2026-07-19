// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {IVaultFull} from "../helpers/IVaultFull.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {IBittyV1PaymentManager} from "../../src/interfaces/IBittyV1PaymentManager.sol";
import {VaultLogic} from "../../src/logic/VaultLogic.sol";
import {
    IBittyV1Vault,
    AddressZero,
    AmountIsZero,
    ScheduledPaymentNotFound,
    ScheduledPaymentImmutable,
    ScheduledPaymentPaymentCountZero,
    ScheduledPaymentIntervalTooShort,
    AssetAddressNotContract,
    NewAddressProtectionOutOfRange,
    NewAddressProtectionCannotDecrease,
    AddressProtectionNotEnded,
    ScheduledPaymentNotStartYet,
    ScheduledPaymentStartTimestampInPast,
    PayMoreThanScheduledPaymentAmount,
    PayScheduledPaymentAmountTriggerEmpty,
    ScheduledPaymentTriggerError,
    ScheduledPaymentInInterval,
    InsufficientBalance,
    NotInitialized,
    WhitelistedRecipientNotFound,
    WhitelistedRecipientAssetNotAllowed,
    PaymentNotApproved,
    NotPendingApproval,
    NotProposalOwner,
    PendingSendNotFound,
    SendingDisabled,
    OwnerAndManagerMustDiffer,
    TransferFailed
} from "../../src/interfaces/IBittyV1Vault.sol";
import {CannotGrantAssetManagerRole} from "../../src/interfaces/IBittyV1AssetManager.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockStakingProtocol} from "../helpers/MockStakingProtocol.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {MockAMMProtocol} from "../helpers/MockAMMProtocol.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "openzeppelin-contracts/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";

/// @dev On receiving native ETH, tries to reenter payScheduled once (swallowing any revert), to prove
/// a reentering recipient cannot double-pay.
contract ReentrantEthReceiver {
    BittyV1Vault public vault;
    uint256 public scheduledPaymentId;
    bool private armed;

    function arm(BittyV1Vault v, uint256 id) external {
        vault = v;
        scheduledPaymentId = id;
        armed = true;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            try vault.payScheduled(scheduledPaymentId) {} catch {}
        }
    }
}

/// @dev Has code but no payable receive/fallback, so a native-ETH transfer to it returns false.
contract RejectEthReceiver {
    function ping() external pure returns (bool) {
        return true;
    }
}

contract BittyV1VaultTest is Test {
    BittyV1Vault public vault;
    address public defiFacet;
    WETH public weth;
    address public guardAddress;
    address public ownerAddress;
    address public assetManagerAddress;

    function setUp() public {
        weth = new WETH();
        defiFacet = address(new BittyV1VaultDeFiFacet());
        vault = new BittyV1Vault();
        guardAddress = address(new BittyV1Guard());
        ownerAddress = tx.origin;
        assetManagerAddress = makeAddr("assetManager");
    }

    function _grantAssetManager(address manager) internal {
        vm.prank(ownerAddress);
        vault.addAssetManager(manager, 0, 0, type(uint64).max, 0);
    }

    function _roleError(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    function _makeScheduledPayment(
        address scheduledPaymentAddress_,
        address trigger_,
        address assetAddress_,
        uint256 amount_,
        uint8 remainingPaymentCount_,
        uint256 startTimestamp_,
        uint256 paymentInterval_,
        bool isImmutable_
    ) internal pure returns (IBittyV1Vault.ScheduledPayment memory) {
        return IBittyV1Vault.ScheduledPayment({
            scheduledPaymentAddress: scheduledPaymentAddress_,
            trigger: trigger_,
            assetAddress: assetAddress_,
            amount: amount_,
            remainingPaymentCount: remainingPaymentCount_,
            startTimestamp: startTimestamp_,
            paymentInterval: paymentInterval_,
            isImmutable: isImmutable_,
            payWithInsufficientBalance: false
        });
    }

    function test_Receive_acceptsPlainEthTransfer() public {
        address depositor = makeAddr("ethDepositor");
        uint256 amount = 0.1 ether;

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success, bytes memory returnData) = address(vault).call{value: amount}("");

        assertTrue(success, string(returnData));
        assertEq(address(vault).balance, amount);
    }

    function test_Receive_acceptsEthBeforeInitialize() public {
        uint256 amount = 1 ether;

        vm.deal(address(this), amount);
        (bool success,) = address(vault).call{value: amount}("");

        assertTrue(success);
        assertEq(address(vault).balance, amount);
    }

    function test_Receive_acceptsEthAfterInitialize() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);

        address depositor = makeAddr("ethDepositor");
        uint256 amount = 0.05 ether;

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success,) = address(vault).call{value: amount}("");

        // Once WETH is configured, receive() auto-wraps: the vault holds WETH, not native ETH.
        assertTrue(success);
        assertEq(address(vault).balance, 0);
        assertEq(weth.balanceOf(address(vault)), amount);
    }

    function test_InitSucceedsWithDifferentAssetManager() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        assertTrue(vault.hasRole(vault.ASSET_MANAGER_ROLE(), assetManagerAddress));
    }

    function test_OwnerMayBeAddedAsAssetManager() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vault.addAssetManager(ownerAddress, 0, 0, type(uint64).max, 0);
        assertTrue(vault.hasRole(vault.ASSET_MANAGER_ROLE(), ownerAddress));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), ownerAddress));
    }

    function test_GrantRoleRevertsForAssetManagerRole() public {
        _initializeVault();
        bytes32 assetManagerRole = vault.ASSET_MANAGER_ROLE();
        address mgr = makeAddr("directGrantMgr");
        vm.prank(ownerAddress);
        vm.expectRevert(CannotGrantAssetManagerRole.selector);
        vault.grantRole(assetManagerRole, mgr);
    }

    function test_GrantRoleRevertsWhenOwnerAsPaymentManager() public {
        _initializeVault();
        bytes32 paymentManagerRole = vault.PAYMENT_MANAGER_ROLE();
        vm.prank(ownerAddress);
        vm.expectRevert(OwnerAndManagerMustDiffer.selector);
        vault.grantRole(paymentManagerRole, ownerAddress);
    }

    // The invariant only excludes the owner — one non-owner account may hold both manager roles.
    function test_ManagerMayHoldBothAssetAndPaymentRoles() public {
        _initializeVault();
        address mgr = makeAddr("mgr");
        bytes32 amRole = vault.ASSET_MANAGER_ROLE();
        bytes32 pmRole = vault.PAYMENT_MANAGER_ROLE();
        vm.startPrank(ownerAddress);
        vault.addAssetManager(mgr, 0, 0, type(uint64).max, 0);
        vault.grantRole(pmRole, mgr);
        vm.stopPrank();
        assertTrue(vault.hasRole(amRole, mgr));
        assertTrue(vault.hasRole(pmRole, mgr));
    }

    function test_GrantRoleRevertsIfAssetManagerGrantedAdminRole() public {
        address assetMgr = makeAddr("assetMgr");
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetMgr);
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(ownerAddress);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        vault.grantRole(adminRole, assetMgr);
    }

    function test_InitErrorWithAlreadyInitialized() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
    }

    function test_AddScheduledPaymentSuccess() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);
    }

    function test_AddScheduledPaymentSuccessSameNameAfterRemoveScheduledPayment() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.startPrank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);
        vault.removeScheduledPayment(aliceId);
        aliceId = vault.addScheduledPayment(r);
        vm.stopPrank();
    }

    function test_AddScheduledPaymentRevertUnauthorized() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        bytes32 _scheduledPaymentRole = vault.PAYMENT_MANAGER_ROLE();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, _scheduledPaymentRole));
        uint256 aliceId = vault.addScheduledPayment(r);
    }

    function test_AddScheduledPaymentRevertAssetAddressNotContract() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), makeAddr("eoaAsset"), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        vm.expectRevert(AssetAddressNotContract.selector);
        uint256 aliceId = vault.addScheduledPayment(r);
    }

    function test_AddScheduledPaymentRevertAmountZero() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 0, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        vm.expectRevert(AmountIsZero.selector);
        uint256 aliceId = vault.addScheduledPayment(r);
    }

    function test_AddScheduledPaymentRevertZeroPayee() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r =
            _makeScheduledPayment(address(0), address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        vm.expectRevert(AddressZero.selector);
        vault.addScheduledPayment(r);
    }

    function test_AddScheduledPaymentRevertPaymentCountZero() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 0, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        uint256 aliceId = vault.addScheduledPayment(r);
    }

    function test_AddScheduledPaymentRevertIntervalTooShortWhenPaymentCountGreaterThanOne() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"),
            address(0),
            address(weth),
            1 ether,
            2,
            block.timestamp,
            VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL - 1,
            false
        );
        vm.prank(ownerAddress);
        vm.expectRevert(ScheduledPaymentIntervalTooShort.selector);
        uint256 aliceId = vault.addScheduledPayment(r);
    }

    function test_AddScheduledPaymentRevertStartTimestampInPast() public {
        _initializeVault();
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp - 1, 1 days, false
        );
        vm.prank(ownerAddress);
        vm.expectRevert(ScheduledPaymentStartTimestampInPast.selector);
        uint256 aliceId = vault.addScheduledPayment(r);
    }

    function test_UpdateScheduledPaymentAllowsPastStartTimestamp() public {
        _initializeVault();
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        r.startTimestamp = block.timestamp - 1;
        vm.prank(ownerAddress);
        vault.updateScheduledPayment(aliceId, r);
    }

    function test_AddScheduledPaymentSuccessWithShortIntervalWhenPaymentCountIsOne() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);
    }

    function test_UpdateScheduledPaymentRevertIntervalTooShortWhenPaymentCountGreaterThanOne() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"),
            address(0),
            address(weth),
            1 ether,
            2,
            block.timestamp,
            VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
            false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        r.paymentInterval = VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL - 1;
        vm.prank(ownerAddress);
        vm.expectRevert(ScheduledPaymentIntervalTooShort.selector);
        vault.updateScheduledPayment(aliceId, r);
    }

    function test_UpdateScheduledPaymentSuccessWithShortIntervalWhenPaymentCountIsOne() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"),
            address(0),
            address(weth),
            1 ether,
            2,
            block.timestamp,
            VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
            false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        r.remainingPaymentCount = 1;
        r.paymentInterval = 0;
        vm.prank(ownerAddress);
        vault.updateScheduledPayment(aliceId, r);
    }

    function test_UpdateScheduledPaymentSuccess() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr,
            address(0),
            address(weth),
            1 ether,
            2,
            block.timestamp,
            VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
            false
        );
        vm.startPrank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);
        r.amount = 2 ether;
        vault.updateScheduledPayment(aliceId, r);
        vm.stopPrank();
    }

    function test_UpdateScheduledPaymentRevertNotFound() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        vm.expectRevert(ScheduledPaymentNotFound.selector);
        vault.updateScheduledPayment(99999, r);
    }

    function test_UpdateScheduledPaymentRevertImmutable() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, true
        );
        vm.startPrank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);
        r.amount = 2 ether;
        vm.expectRevert(ScheduledPaymentImmutable.selector);
        vault.updateScheduledPayment(aliceId, r);
        vm.stopPrank();
    }

    function test_UpdateScheduledPaymentRevertOnlyOwner() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);
        r.amount = 2 ether;
        bytes32 _scheduledPaymentRole = vault.PAYMENT_MANAGER_ROLE();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, _scheduledPaymentRole));
        vault.updateScheduledPayment(aliceId, r);
    }

    function test_RemoveScheduledPaymentSuccess() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.startPrank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);
        vault.removeScheduledPayment(aliceId);
        vm.stopPrank();
        vm.expectRevert(ScheduledPaymentNotFound.selector);
        vault.payScheduled(aliceId);
    }

    function test_RemoveScheduledPaymentRevertOnlyOwner() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);
        bytes32 _scheduledPaymentRole = vault.PAYMENT_MANAGER_ROLE();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, _scheduledPaymentRole));
        vault.removeScheduledPayment(aliceId);
    }

    function test_PayScheduledPayment_revertScheduledPaymentNotStartYet() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        uint256 futureStartTimestamp = block.timestamp + 100;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, futureStartTimestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        vm.expectRevert(ScheduledPaymentNotStartYet.selector);
        vault.payScheduled(aliceId);
    }

    function test_PayScheduledPayment_singlePaymentWithZeroInterval() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        deal(address(weth), address(vault), 1 ether);

        vault.payScheduled(aliceId);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);

        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        vault.payScheduled(aliceId);
    }

    function test_PayScheduledPayment_scheduledPaymentStorageUpdatedSoPaymentCountEnforced() public {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        vm.warp(1000);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr,
            address(0),
            address(weth),
            1 ether,
            2,
            block.timestamp,
            VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
            false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        deal(address(weth), address(vault), 2 ether);

        vault.payScheduled(aliceId);
        vm.warp(block.timestamp + VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL);
        vault.payScheduled(aliceId);

        assertEq(weth.balanceOf(scheduledPaymentAddr), 2 ether, "scheduledPayment should have received 2 payments");

        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        vault.payScheduled(aliceId);
    }

    function test_SetNewAddressProtectionRevertUnauthorizedWhenNotInitialized() public {
        vm.expectRevert(); // no roles granted before initialize, AccessControl fires first
        vault.setNewAddressProtection(1 days);
    }

    function test_SetNewAddressProtectionRevertUnauthorized() public {
        _initializeVault();
        bytes32 _adminRole = vault.DEFAULT_ADMIN_ROLE();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, _adminRole));
        vault.setNewAddressProtection(1 days);
    }

    function test_SetNewAddressProtectionRevertOutOfRange() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(NewAddressProtectionOutOfRange.selector);
        vault.setNewAddressProtection(VaultLogic.NEW_ADDRESS_PROTECTION_MAX + 1);
    }

    function test_SetNewAddressProtectionRevertCannotDisable() public {
        _initializeVault();
        // A compromised owner must not be able to drop protection to 0 and drain immediately.
        vm.prank(ownerAddress);
        vm.expectRevert(NewAddressProtectionOutOfRange.selector);
        vault.setNewAddressProtection(0);
    }

    function test_SetNewAddressProtectionRevertBelowMin() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(NewAddressProtectionOutOfRange.selector);
        vault.setNewAddressProtection(VaultLogic.NEW_ADDRESS_PROTECTION_MIN - 1);
    }

    function test_SetNewAddressProtectionSuccessAtMin() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vault.setNewAddressProtection(VaultLogic.NEW_ADDRESS_PROTECTION_MIN);
    }

    function test_SetNewAddressProtectionSuccessAtMax() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vault.setNewAddressProtection(VaultLogic.NEW_ADDRESS_PROTECTION_MAX);
    }

    function test_SetNewAddressProtectionCanIncrease() public {
        _initializeVault();
        vm.startPrank(ownerAddress);
        vault.setNewAddressProtection(2 days);
        vault.setNewAddressProtection(2 days); // equal is a no-op, allowed
        vault.setNewAddressProtection(5 days); // raising is allowed
        vm.stopPrank();
    }

    function test_SetNewAddressProtectionRevertCannotDecrease() public {
        _initializeVault();
        // A compromised owner key must not be able to weaken an already-configured window.
        vm.startPrank(ownerAddress);
        vault.setNewAddressProtection(10 days);
        vm.expectRevert(NewAddressProtectionCannotDecrease.selector);
        vault.setNewAddressProtection(5 days);
        vm.stopPrank();
    }

    function test_PayScheduledPayment_revertAddressProtectionNotEnded() public {
        _initializeVault();
        uint256 protection = 3 days;
        vm.prank(ownerAddress);
        vault.setNewAddressProtection(protection);

        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        deal(address(weth), address(vault), 1 ether);

        vm.expectRevert(AddressProtectionNotEnded.selector);
        vault.payScheduled(aliceId);
    }

    function test_PayScheduledPayment_successAfterScheduledPaymentProtectionEnds() public {
        _initializeVault();
        uint256 protection = 3 days;
        vm.prank(ownerAddress);
        vault.setNewAddressProtection(protection);

        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        uint256 addedAt = block.timestamp;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        deal(address(weth), address(vault), 1 ether);

        vm.warp(addedAt + protection);
        vault.payScheduled(aliceId);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
    }

    function test_PayScheduledPayment_noProtectionWhenProtectionIsZero() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        deal(address(weth), address(vault), 1 ether);

        vault.payScheduled(aliceId);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
    }

    function test_PayScheduledPayment_protectionOnlyAppliesToScheduledPaymentsAddedWhileEnabled() public {
        _initializeVault();
        address aliceScheduledPayment = makeAddr("aliceScheduledPayment");
        address bobScheduledPayment = makeAddr("bobScheduledPayment");

        // bob is added before protection is ever enabled (default-0, opt-in), so it is unprotected.
        IBittyV1Vault.ScheduledPayment memory bob = _makeScheduledPayment(
            bobScheduledPayment, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 bobId = vault.addScheduledPayment(bob);

        // Enabling protection only time-locks addresses introduced from now on.
        vm.prank(ownerAddress);
        vault.setNewAddressProtection(2 days);

        IBittyV1Vault.ScheduledPayment memory alice = _makeScheduledPayment(
            aliceScheduledPayment, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(alice);

        deal(address(weth), address(vault), 2 ether);

        vm.expectRevert(AddressProtectionNotEnded.selector);
        vault.payScheduled(aliceId);

        vault.payScheduled(bobId);
        assertEq(weth.balanceOf(bobScheduledPayment), 1 ether);
    }

    function test_RemoveScheduledPayment_clearsProtectionSoReAddCanPayAfterProtection() public {
        _initializeVault();
        uint256 protection = 1 days;
        address scheduledPaymentAddr = makeAddr("scheduledPayment");

        vm.prank(ownerAddress);
        vault.setNewAddressProtection(protection);

        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.startPrank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);
        vault.removeScheduledPayment(aliceId);
        aliceId = vault.addScheduledPayment(r);
        vm.stopPrank();

        deal(address(weth), address(vault), 1 ether);

        vm.expectRevert(AddressProtectionNotEnded.selector);
        vault.payScheduled(aliceId);

        vm.warp(block.timestamp + protection);
        vault.payScheduled(aliceId);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
    }

    function test_RemoveScheduledPayment_clearsLastReceiveTimestampSoReAddCanPayImmediately() public {
        _initializeVault();
        vm.warp(1_000_000);
        address scheduledPaymentAddr = makeAddr("scheduledPayment");

        uint256 aliceId =
            _addScheduledPayment(scheduledPaymentAddr, 1 ether, 2, VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL);
        deal(address(weth), address(vault), 3 ether);
        vault.payScheduled(aliceId);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);

        vm.prank(ownerAddress);
        vault.removeScheduledPayment(aliceId);
        aliceId = _addScheduledPayment(scheduledPaymentAddr, 1 ether, 1, VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL);

        vault.payScheduled(aliceId);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 2 ether, "re-added scheduledPayment must be payable immediately");
    }

    function test_PayScheduledPayment_revertNotInitialized() public {
        vm.expectRevert(NotInitialized.selector);
        vault.payScheduled(1);
    }

    function test_PayScheduledPaymentAmount_revertNotInitialized() public {
        vm.expectRevert(NotInitialized.selector);
        vault.payScheduledAmount(1, 1);
    }

    function test_PayScheduledPaymentAmount_revertTriggerEmpty() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        uint256 aliceId = _addScheduledPayment(scheduledPaymentAddr, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.expectRevert(PayScheduledPaymentAmountTriggerEmpty.selector);
        vault.payScheduledAmount(aliceId, 1 ether);
    }

    function test_PayScheduledPaymentAmount_revertWhenCallerIsNotTrigger() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        address attacker = makeAddr("attacker");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(attacker);
        vm.expectRevert(ScheduledPaymentTriggerError.selector);
        vault.payScheduledAmount(aliceId, 1 ether);

        assertEq(weth.balanceOf(scheduledPaymentAddr), 0);

        vm.prank(trigger);
        vault.payScheduledAmount(aliceId, 1 ether);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
    }

    function test_PayScheduled_revertWhenCallerIsNotTrigger() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        address attacker = makeAddr("attacker");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(attacker);
        vm.expectRevert(ScheduledPaymentTriggerError.selector);
        vault.payScheduled(aliceId);

        vm.prank(trigger);
        vault.payScheduled(aliceId);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
    }

    function test_PayScheduledPaymentAmount_successWhenAmountEqualsScheduledPaymentAmount() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vault.payScheduledAmount(aliceId, 1 ether);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);

        vm.prank(trigger);
        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        vault.payScheduledAmount(aliceId, 1 ether);
    }

    function test_PayScheduledPaymentAmount_successWhenAmountLessThanScheduledPaymentAmount() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vault.payScheduledAmount(aliceId, 0.5 ether);

        assertEq(weth.balanceOf(scheduledPaymentAddr), 0.5 ether, "transfers requested partial amount");
        assertEq(weth.balanceOf(address(vault)), 0.5 ether, "vault retains the remainder");
    }

    function test_PayScheduledPaymentAmount_partialAmountEmitsPaidAmount() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IBittyV1Vault.ScheduledPaymentPaid(aliceId, scheduledPaymentAddr, address(weth), 0.25 ether, 0);
        vault.payScheduledAmount(aliceId, 0.25 ether);

        assertEq(weth.balanceOf(scheduledPaymentAddr), 0.25 ether);
    }

    function test_PayScheduledPaymentAmount_revertPayMoreThanScheduledPaymentAmount() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectRevert(PayMoreThanScheduledPaymentAmount.selector);
        vault.payScheduledAmount(aliceId, 1 ether + 1);
    }

    function test_PayScheduledPaymentAmount_revertScheduledPaymentNotStartYet() public {
        _initializeVault();
        uint256 futureStart = block.timestamp + 100;
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        IBittyV1Vault.ScheduledPayment memory r =
            _makeScheduledPayment(scheduledPaymentAddr, trigger, address(weth), 1 ether, 1, futureStart, 0, false);
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectRevert(ScheduledPaymentNotStartYet.selector);
        vault.payScheduledAmount(aliceId, 1 ether);
    }

    function test_PayScheduledPaymentAmount_revertAddressProtectionNotEnded() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vault.setNewAddressProtection(2 days);

        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectRevert(AddressProtectionNotEnded.selector);
        vault.payScheduledAmount(aliceId, 1 ether);
    }

    function test_PayScheduledPaymentAmount_revertInsufficientBalance() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 0.5 ether);

        vm.prank(trigger);
        vm.expectRevert(InsufficientBalance.selector);
        vault.payScheduledAmount(aliceId, 1 ether);
    }

    function test_PayScheduledPayment_revertInsufficientBalance_whenPayWithInsufficientBalanceFalse() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        deal(address(weth), address(vault), 0.5 ether);

        vm.expectRevert(InsufficientBalance.selector);
        vault.payScheduled(aliceId);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 0, "no partial transfer on revert");
    }

    function test_PayScheduledPayment_paysAvailableBalance_whenPayWithInsufficientBalanceTrue() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        uint256 vaultBalance = 0.5 ether;
        IBittyV1Vault.ScheduledPayment memory r = IBittyV1Vault.ScheduledPayment({
            scheduledPaymentAddress: scheduledPaymentAddr,
            trigger: address(0),
            assetAddress: address(weth),
            amount: 1 ether,
            remainingPaymentCount: 1,
            startTimestamp: block.timestamp,
            paymentInterval: 0,
            isImmutable: false,
            payWithInsufficientBalance: true
        });
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        deal(address(weth), address(vault), vaultBalance);

        vault.payScheduled(aliceId);

        assertEq(weth.balanceOf(scheduledPaymentAddr), vaultBalance, "transfers entire vault balance");
        assertEq(weth.balanceOf(address(vault)), 0);
        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        vault.payScheduled(aliceId);
    }

    function test_PayScheduledPayment_paysFullAmount_whenPayWithInsufficientBalanceTrueAndBalanceSufficient() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = IBittyV1Vault.ScheduledPayment({
            scheduledPaymentAddress: scheduledPaymentAddr,
            trigger: address(0),
            assetAddress: address(weth),
            amount: 1 ether,
            remainingPaymentCount: 1,
            startTimestamp: block.timestamp,
            paymentInterval: 0,
            isImmutable: false,
            payWithInsufficientBalance: true
        });
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        deal(address(weth), address(vault), 1 ether);

        vault.payScheduled(aliceId);

        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    function test_PayScheduledPayment_partialPaymentsAcrossMultiplePayouts_whenPayWithInsufficientBalanceTrue() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        uint256 start = block.timestamp;
        IBittyV1Vault.ScheduledPayment memory r = IBittyV1Vault.ScheduledPayment({
            scheduledPaymentAddress: scheduledPaymentAddr,
            trigger: address(0),
            assetAddress: address(weth),
            amount: 1 ether,
            remainingPaymentCount: 3,
            startTimestamp: start,
            paymentInterval: VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
            isImmutable: false,
            payWithInsufficientBalance: true
        });
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        deal(address(weth), address(vault), 1.5 ether);

        vault.payScheduled(aliceId);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);

        vm.warp(start + VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL + 1);
        vault.payScheduled(aliceId);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1.5 ether, "second payout sends remaining 0.5 ether");

        vm.warp(start + 2 * (VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL + 1));
        vault.payScheduled(aliceId);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1.5 ether, "third payout with zero balance sends nothing");

        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        vault.payScheduled(aliceId);
    }

    // ─── ScheduledPayment Events ──────────────────────────────────────────────────────

    function test_AddScheduledPayment_emitsScheduledPaymentAddedEvent() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );

        vm.expectEmit(true, false, false, true, address(vault));
        emit IBittyV1PaymentManager.ScheduledPaymentAdded(1, r);

        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);
    }

    function test_UpdateScheduledPayment_emitsScheduledPaymentUpdatedEvent() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        IBittyV1Vault.ScheduledPayment memory updated = _makeScheduledPayment(
            scheduledPaymentAddr,
            address(0),
            address(weth),
            2 ether,
            2,
            block.timestamp,
            VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
            false
        );

        vm.expectEmit(true, false, false, true, address(vault));
        emit IBittyV1PaymentManager.ScheduledPaymentUpdated(aliceId, updated);

        vm.prank(ownerAddress);
        vault.updateScheduledPayment(aliceId, updated);
    }

    function test_RemoveScheduledPayment_emitsScheduledPaymentRemovedEvent() public {
        _initializeVault();
        uint256 aliceId = _addScheduledPayment(makeAddr("scheduledPayment"), 1 ether, 1, 0);

        vm.expectEmit(true, false, false, false, address(vault));
        emit IBittyV1PaymentManager.ScheduledPaymentRemoved(aliceId);

        vm.prank(ownerAddress);
        vault.removeScheduledPayment(aliceId);
    }

    function test_SetNewAddressProtection_emitsNewAddressProtectionSetEvent() public {
        _initializeVault();
        uint256 protection = 1 days;

        vm.expectEmit(false, false, false, true, address(vault));
        emit IBittyV1Owner.NewAddressProtectionSet(protection);

        vm.prank(ownerAddress);
        vault.setNewAddressProtection(protection);
    }

    function test_PayScheduledPayment_emitsScheduledPaymentPaidEvent() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        uint256 aliceId =
            _addScheduledPayment(scheduledPaymentAddr, 1 ether, 2, VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL);
        deal(address(weth), address(vault), 1 ether);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IBittyV1Vault.ScheduledPaymentPaid(aliceId, scheduledPaymentAddr, address(weth), 1 ether, 1);

        vault.payScheduled(aliceId);
    }

    function test_PayScheduledPaymentAmount_emitsScheduledPaymentPaidEvent() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);
        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IBittyV1Vault.ScheduledPaymentPaid(aliceId, scheduledPaymentAddr, address(weth), 1 ether, 0);
        vault.payScheduledAmount(aliceId, 1 ether);
    }

    function test_PayScheduledPayment_emitsScheduledPaymentPaidEvent_withPartialBalance() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        uint256 vaultBalance = 0.5 ether;
        IBittyV1Vault.ScheduledPayment memory r = IBittyV1Vault.ScheduledPayment({
            scheduledPaymentAddress: scheduledPaymentAddr,
            trigger: address(0),
            assetAddress: address(weth),
            amount: 1 ether,
            remainingPaymentCount: 1,
            startTimestamp: block.timestamp,
            paymentInterval: 0,
            isImmutable: false,
            payWithInsufficientBalance: true
        });
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);
        deal(address(weth), address(vault), vaultBalance);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IBittyV1Vault.ScheduledPaymentPaid(aliceId, scheduledPaymentAddr, address(weth), vaultBalance, 0);

        vault.payScheduled(aliceId);
    }

    // ─── Fuzz Tests ───────────────────────────────────────────────────────────

    function testFuzz_AddScheduledPayment_validAmountAndCount(uint256 amount, uint8 remainingPaymentCount) public {
        vm.assume(amount > 0 && remainingPaymentCount > 0);
        _initializeVault();
        uint256 interval = remainingPaymentCount > 1 ? VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL : 0;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("r"), address(0), address(weth), amount, remainingPaymentCount, block.timestamp, interval, false
        );
        vm.prank(ownerAddress);
        uint256 rId = vault.addScheduledPayment(r);
    }

    function testFuzz_SetNewAddressProtection_withinBounds(uint256 protection) public {
        protection = bound(protection, VaultLogic.NEW_ADDRESS_PROTECTION_MIN, VaultLogic.NEW_ADDRESS_PROTECTION_MAX);
        _initializeVault();
        vm.prank(ownerAddress);
        vault.setNewAddressProtection(protection);
    }

    function testFuzz_SetNewAddressProtection_rejectsAboveMax(uint256 protection) public {
        vm.assume(protection > VaultLogic.NEW_ADDRESS_PROTECTION_MAX);
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(NewAddressProtectionOutOfRange.selector);
        vault.setNewAddressProtection(protection);
    }

    function testFuzz_SetNewAddressProtection_rejectsBelowMin(uint256 protection) public {
        protection = bound(protection, 0, VaultLogic.NEW_ADDRESS_PROTECTION_MIN - 1);
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(NewAddressProtectionOutOfRange.selector);
        vault.setNewAddressProtection(protection);
    }

    function testFuzz_ScheduledPaymentProtection_blocksDuringWindow(uint256 protection, uint256 elapsed) public {
        protection = bound(protection, VaultLogic.NEW_ADDRESS_PROTECTION_MIN, VaultLogic.NEW_ADDRESS_PROTECTION_MAX);
        elapsed = bound(elapsed, 0, protection - 1);
        _initializeVault();
        vm.prank(ownerAddress);
        vault.setNewAddressProtection(protection);
        address scheduledPaymentAddr = makeAddr("r");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 rId = vault.addScheduledPayment(r);
        deal(address(weth), address(vault), 1 ether);
        vm.warp(block.timestamp + elapsed);
        vm.expectRevert(AddressProtectionNotEnded.selector);
        vault.payScheduled(rId);
    }

    function testFuzz_ScheduledPaymentProtection_allowsAfterWindow(uint256 protection, uint256 extra) public {
        protection = bound(protection, VaultLogic.NEW_ADDRESS_PROTECTION_MIN, VaultLogic.NEW_ADDRESS_PROTECTION_MAX);
        extra = bound(extra, 0, 365 days);
        _initializeVault();
        vm.prank(ownerAddress);
        vault.setNewAddressProtection(protection);
        address scheduledPaymentAddr = makeAddr("r");
        uint256 addedAt = block.timestamp;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 rId = vault.addScheduledPayment(r);
        deal(address(weth), address(vault), 1 ether);
        vm.warp(addedAt + protection + extra);
        vault.payScheduled(rId);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
    }

    function testFuzz_PayScheduledPayment_allPaymentsComplete(uint8 remainingPaymentCount) public {
        remainingPaymentCount = uint8(bound(uint256(remainingPaymentCount), 1, 10));
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("r");
        uint256 amount = 0.1 ether;
        uint256 start = block.timestamp;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr,
            address(0),
            address(weth),
            amount,
            remainingPaymentCount,
            start,
            remainingPaymentCount > 1 ? VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL : 0,
            false
        );
        vm.prank(ownerAddress);
        uint256 rId = vault.addScheduledPayment(r);
        deal(address(weth), address(vault), uint256(remainingPaymentCount) * amount);
        vault.payScheduled(rId);
        for (uint8 i = 1; i < remainingPaymentCount; i++) {
            vm.warp(start + uint256(i) * VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL);
            vault.payScheduled(rId);
        }
        assertEq(weth.balanceOf(scheduledPaymentAddr), uint256(remainingPaymentCount) * amount);
        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        vault.payScheduled(rId);
    }

    // ─── Stress Tests ─────────────────────────────────────────────────────────

    function test_stress_fiftyScheduledPayments_addAndPayAll() public {
        _initializeVault();
        uint256 n = 50;
        uint256 amount = 0.01 ether;
        deal(address(weth), address(vault), n * amount);
        address[] memory scheduledPayments = new address[](n);
        uint256[] memory spIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            scheduledPayments[i] = makeAddr(string.concat("r", Strings.toString(i)));
            IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
                scheduledPayments[i], address(0), address(weth), amount, 1, block.timestamp, 0, false
            );
            vm.prank(ownerAddress);
            spIds[i] = vault.addScheduledPayment(r);
        }
        for (uint256 i = 0; i < n; i++) {
            vault.payScheduled(spIds[i]);
            assertEq(weth.balanceOf(scheduledPayments[i]), amount);
        }
    }

    function test_stress_twentySequentialPayments() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("r");
        uint8 remainingPaymentCount = 20;
        uint256 amount = 0.05 ether;
        uint256 start = block.timestamp;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr,
            address(0),
            address(weth),
            amount,
            remainingPaymentCount,
            start,
            VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
            false
        );
        vm.prank(ownerAddress);
        uint256 rId = vault.addScheduledPayment(r);
        deal(address(weth), address(vault), uint256(remainingPaymentCount) * amount);
        vault.payScheduled(rId);
        for (uint8 i = 1; i < remainingPaymentCount; i++) {
            vm.warp(start + uint256(i) * VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL);
            vault.payScheduled(rId);
        }
        assertEq(weth.balanceOf(scheduledPaymentAddr), uint256(remainingPaymentCount) * amount);
        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        vault.payScheduled(rId);
    }

    function _addScheduledPayment(
        address scheduledPaymentAddr,
        uint256 amount,
        uint8 remainingPaymentCount,
        uint256 paymentInterval
    ) internal returns (uint256 id) {
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr,
            address(0),
            address(weth),
            amount,
            remainingPaymentCount,
            block.timestamp,
            paymentInterval,
            false
        );
        vm.prank(ownerAddress);
        id = vault.addScheduledPayment(r);
    }

    function _addScheduledPaymentWithTrigger(
        address scheduledPaymentAddr,
        address trigger,
        uint256 amount,
        uint8 remainingPaymentCount,
        uint256 paymentInterval
    ) internal returns (uint256 id) {
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr,
            trigger,
            address(weth),
            amount,
            remainingPaymentCount,
            block.timestamp,
            paymentInterval,
            false
        );
        vm.prank(ownerAddress);
        id = vault.addScheduledPayment(r);
    }

    function _addWhitelistedRecipient(address recipient, address allowedAsset) internal returns (uint256 id) {
        vm.prank(ownerAddress);
        id = vault.addWhitelistedRecipient(recipient, allowedAsset);
    }

    function _initializeVault() internal {
        vault.initialize(
            ownerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            defiFacet
        );
        _grantAssetManager(assetManagerAddress);
    }

    function test_defaultAdminDelay_isOneDayConstant() public {
        assertEq(vault.OWNER_TRANSFER_DELAY(), 1 days);
        _initializeVault();
        assertEq(vault.defaultAdminDelay(), 1 days);
        assertEq(vault.defaultAdmin(), ownerAddress);
    }

    function test_defaultAdmin_ownerCanActInstantly() public {
        _initializeVault();
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), ownerAddress));

        address newManager = makeAddr("instantManager");
        bytes32 role = vault.ASSET_MANAGER_ROLE();
        vm.prank(ownerAddress);
        vault.addAssetManager(newManager, 0, 0, type(uint64).max, 0);
        assertTrue(vault.hasRole(role, newManager));
    }

    function test_acceptDefaultAdminTransfer_revertsBeforeOneDay() public {
        _initializeVault();
        address newAdmin = makeAddr("newAdmin");

        vm.prank(ownerAddress);
        vault.beginDefaultAdminTransfer(newAdmin);

        (, uint48 schedule) = vault.pendingDefaultAdmin();
        vm.prank(newAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        vault.acceptDefaultAdminTransfer();
    }

    function test_acceptDefaultAdminTransfer_succeedsAfterOneDay() public {
        _initializeVault();
        address newAdmin = makeAddr("newAdmin");

        vm.prank(ownerAddress);
        vault.beginDefaultAdminTransfer(newAdmin);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(newAdmin);
        vault.acceptDefaultAdminTransfer();

        assertEq(vault.defaultAdmin(), newAdmin);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), newAdmin));
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), ownerAddress));
    }

    function test_beginDefaultAdminTransfer_allowsAssetManager() public {
        _initializeVault();

        vm.prank(ownerAddress);
        vault.beginDefaultAdminTransfer(assetManagerAddress);

        (address pending,) = vault.pendingDefaultAdmin();
        assertEq(pending, assetManagerAddress);
    }

    function test_AdminTransferSucceedsWhenNewAdminIsAssetManager() public {
        _initializeVault();
        bytes32 assetManagerRole = vault.ASSET_MANAGER_ROLE();
        address newAdmin = makeAddr("newAdmin");

        vm.prank(ownerAddress);
        vault.beginDefaultAdminTransfer(newAdmin);

        // The owner and an asset manager may be the same account, so the pending admin holding
        // ASSET_MANAGER_ROLE does not block the transfer.
        vm.prank(ownerAddress);
        vault.addAssetManager(newAdmin, 0, 0, type(uint64).max, 0);
        assertTrue(vault.hasRole(assetManagerRole, newAdmin));

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(newAdmin);
        vault.acceptDefaultAdminTransfer();
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), newAdmin));
        assertTrue(vault.hasRole(assetManagerRole, newAdmin));
    }

    function test_renounceDefaultAdmin_requiresTransferToZeroAndDelay() public {
        _initializeVault();
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();

        vm.prank(ownerAddress);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, 0)
        );
        vault.renounceRole(adminRole, ownerAddress);

        vm.prank(ownerAddress);
        vault.beginDefaultAdminTransfer(address(0));

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(ownerAddress);
        vault.renounceRole(adminRole, ownerAddress);

        assertEq(vault.defaultAdmin(), address(0));
        assertFalse(vault.hasRole(adminRole, ownerAddress));
    }

    // ─── Unified addAssets / removeAssets ─────────────────────────────────────

    function test_AddAssets_addsRegisteredStableCoinToStableCoinsSet() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(usdc);

        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addStableCoins(toAdd);

        vm.prank(ownerAddress);
        vault.addAssets(toAdd);

        address[] memory stableCoins = vault.getStableCoins();
        assertEq(stableCoins.length, 1);
        assertEq(stableCoins[0], address(usdc));
        assertEq(vault.getAssets().length, 0);
    }

    function test_AddAssets_addsRegisteredAssetToAssetsSet() public {
        _initializeVault();
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(dai);

        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addAssets(toAdd);

        vm.prank(ownerAddress);
        vault.addAssets(toAdd);

        address[] memory assets = vault.getAssets();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(dai));
        assertEq(vault.getStableCoins().length, 0);
    }

    function test_RemoveAssets_removesStableCoinFromStableCoinsSet() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(usdc);

        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addStableCoins(toAdd);
        vm.prank(ownerAddress);
        vault.addAssets(toAdd);

        vm.prank(ownerAddress);
        vault.removeAssets(toAdd);

        assertEq(vault.getStableCoins().length, 0);
    }

    function test_RemoveAssets_removesAssetFromAssetsSet() public {
        _initializeVault();
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(dai);

        vm.prank(tx.origin);
        BittyV1Guard(guardAddress).addAssets(toAdd);
        vm.prank(ownerAddress);
        vault.addAssets(toAdd);

        vm.prank(ownerAddress);
        vault.removeAssets(toAdd);

        assertEq(vault.getAssets().length, 0);
    }

    function test_AddAssets_revertsWhenNotRegisteredOnGuard() public {
        _initializeVault();
        address unregistered = makeAddr("unregistered");
        address[] memory toAdd = new address[](1);
        toAdd[0] = unregistered;

        vm.prank(ownerAddress);
        vm.expectRevert(NotRegistered.selector);
        vault.addAssets(toAdd);
    }

    function test_RemoveAssets_revertsWhenNotInVault() public {
        _initializeVault();
        address unregistered = makeAddr("unregistered");
        address[] memory toRemove = new address[](1);
        toRemove[0] = unregistered;

        vm.prank(ownerAddress);
        vm.expectRevert(NotRegistered.selector);
        vault.removeAssets(toRemove);
    }

    // ============ Pay scheduledPayment directly from yield (on-behalf) ============

    function _arr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    /// @dev Registers a staking mock in the guard + vault, funds the vault, and stakes it.
    function _setupStakedReserve(MockERC20 usdc, MockStakingProtocol impl, uint256 stakeAmount) internal {
        vm.prank(ownerAddress);
        BittyV1Guard(guardAddress).addStakingProtocols(_arr(address(impl)));
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).addStakingProtocols(_arr(address(impl)));

        usdc.mint(address(vault), stakeAmount);
        vm.prank(assetManagerAddress);
        IVaultFull(payable(address(vault))).stake(address(impl), address(usdc), stakeAmount);
    }

    /// @dev Registers a lending mock in the guard + vault, funds the vault, and supplies it.
    function _setupSuppliedReserve(MockERC20 usdc, MockLendingProtocol impl, uint256 supplyAmount) internal {
        vm.prank(ownerAddress);
        BittyV1Guard(guardAddress).addLendingProtocols(_arr(address(impl)));
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).addLendingProtocols(_arr(address(impl)));

        usdc.mint(address(vault), supplyAmount);
        vm.prank(assetManagerAddress);
        IVaultFull(payable(address(vault))).supply(address(impl), address(usdc), supplyAmount);
    }

    function test_payScheduledFromStaking_deliversDirectlyToScheduledPayment() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockStakingProtocol impl = new MockStakingProtocol();
        address scheduledPaymentAddr = makeAddr("rentScheduledPayment");

        uint256 stakeAmount = 1_000e6;
        uint256 payAmount = 250e6;
        _setupStakedReserve(usdc, impl, stakeAmount);

        vm.prank(ownerAddress);
        uint256 rentId = vault.addScheduledPayment(
            _makeScheduledPayment(
                scheduledPaymentAddr,
                address(0),
                address(usdc),
                payAmount,
                3,
                block.timestamp,
                VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
                false
            )
        );

        // Triggerless scheduledPayment → callable by anyone.
        vm.prank(makeAddr("caller"));
        vault.payScheduledFromStaking(rentId, address(impl));

        assertEq(usdc.balanceOf(scheduledPaymentAddr), payAmount);
        assertEq(usdc.balanceOf(address(vault)), 0);

        address clone = IVaultFull(payable(address(vault))).getClone(address(impl));
        assertEq(MockStakingProtocol(clone).lastUnstakeRecipient(), scheduledPaymentAddr);
        assertEq(MockStakingProtocol(clone).lastUnstakeAmount(), payAmount);
        assertEq(
            IVaultFull(payable(address(vault))).getStakedBalance(address(impl), address(usdc)), stakeAmount - payAmount
        );
    }

    function test_payScheduledFromLending_deliversDirectlyToScheduledPayment() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockLendingProtocol impl = new MockLendingProtocol();
        address scheduledPaymentAddr = makeAddr("payrollScheduledPayment");

        uint256 supplyAmount = 800e6;
        uint256 payAmount = 300e6;
        _setupSuppliedReserve(usdc, impl, supplyAmount);

        vm.prank(ownerAddress);
        uint256 payrollId = vault.addScheduledPayment(
            _makeScheduledPayment(
                scheduledPaymentAddr,
                address(0),
                address(usdc),
                payAmount,
                2,
                block.timestamp,
                VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
                false
            )
        );

        vm.prank(makeAddr("caller"));
        vault.payScheduledFromLending(payrollId, address(impl));

        assertEq(usdc.balanceOf(scheduledPaymentAddr), payAmount);
        assertEq(usdc.balanceOf(address(vault)), 0);

        address clone = IVaultFull(payable(address(vault))).getClone(address(impl));
        assertEq(MockLendingProtocol(clone).lastWithdrawRecipient(), scheduledPaymentAddr);
        assertEq(MockLendingProtocol(clone).lastWithdrawAmount(), payAmount);
        assertEq(
            IVaultFull(payable(address(vault))).getSuppliedBalance(address(impl), address(usdc)),
            supplyAmount - payAmount
        );
    }

    function test_payScheduledFromSwap_deliversDirectlyToScheduledPayment() public {
        _initializeVault();
        MockERC20 fromAsset = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 payAsset = new MockERC20("USD Coin", "USDC", 6);
        MockAMMProtocol amm = new MockAMMProtocol();
        address scheduledPaymentAddr = makeAddr("swapScheduledPayment");

        vm.startPrank(ownerAddress);
        BittyV1Guard(guardAddress).addAssets(_arr(address(fromAsset)));
        BittyV1Guard(guardAddress).addAssets(_arr(address(payAsset)));
        vault.addAssets(_arr(address(fromAsset)));
        vault.addAssets(_arr(address(payAsset)));
        BittyV1Guard(guardAddress).addAMMProtocols(_arr(address(amm)));
        IVaultFull(payable(address(vault))).addAMMProtocols(_arr(address(amm)));
        vm.stopPrank();

        uint256 sellAmountMax = 1 ether;
        uint256 payAmount = 300e6;
        fromAsset.mint(address(vault), sellAmountMax);

        vm.prank(ownerAddress);
        uint256 payrollId = vault.addScheduledPayment(
            _makeScheduledPayment(
                scheduledPaymentAddr,
                address(0),
                address(payAsset),
                payAmount,
                2,
                block.timestamp,
                VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
                false
            )
        );

        bytes memory data = abi.encode(address(fromAsset), sellAmountMax, address(payAsset), payAmount, bytes(""));

        // Triggerless scheduledPayment → callable by anyone.
        vm.prank(makeAddr("caller"));
        vault.payScheduledFromSwap(payrollId, address(amm), address(fromAsset), sellAmountMax, data);

        assertEq(
            payAsset.balanceOf(scheduledPaymentAddr), payAmount, "scheduledPayment paid exactly the scheduled amount"
        );
        assertEq(payAsset.balanceOf(address(vault)), 0, "vault holds none of the bought asset");
        assertEq(fromAsset.balanceOf(address(vault)), 0, "vault spent the sell asset");

        address clone = IVaultFull(payable(address(vault))).getClone(address(amm));
        assertEq(
            MockAMMProtocol(clone).lastSwapRecipient(), scheduledPaymentAddr, "swap delivered to the scheduledPayment"
        );
        assertEq(MockAMMProtocol(clone).lastSwapBuyAmount(), payAmount);
    }

    function test_payScheduledFromSwap_bypassesMinimalBalanceGuard() public {
        _initializeVault();
        MockERC20 fromAsset = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 payAsset = new MockERC20("USD Coin", "USDC", 6);
        MockAMMProtocol amm = new MockAMMProtocol();
        address scheduledPaymentAddr = makeAddr("swapScheduledPayment2");

        vm.startPrank(ownerAddress);
        BittyV1Guard(guardAddress).addAssets(_arr(address(fromAsset)));
        BittyV1Guard(guardAddress).addAssets(_arr(address(payAsset)));
        vault.addAssets(_arr(address(fromAsset)));
        vault.addAssets(_arr(address(payAsset)));
        BittyV1Guard(guardAddress).addAMMProtocols(_arr(address(amm)));
        IVaultFull(payable(address(vault))).addAMMProtocols(_arr(address(amm)));
        vm.stopPrank();

        uint256 sellAmountMax = 1 ether;
        uint256 payAmount = 300e6;
        fromAsset.mint(address(vault), 2 ether);

        // Post-swap balance (2 - 1 = 1) breaches this minimum. An asset-manager marketBuy would revert
        // MinimalBalanceNotMet, but the owner-scheduled scheduledPayment payment outranks the guard.
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).setMinimalBalance(address(fromAsset), 1.5 ether);

        vm.prank(ownerAddress);
        uint256 payrollId = vault.addScheduledPayment(
            _makeScheduledPayment(
                scheduledPaymentAddr,
                address(0),
                address(payAsset),
                payAmount,
                2,
                block.timestamp,
                VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
                false
            )
        );

        bytes memory data = abi.encode(address(fromAsset), sellAmountMax, address(payAsset), payAmount, bytes(""));

        vm.prank(makeAddr("caller"));
        vault.payScheduledFromSwap(payrollId, address(amm), address(fromAsset), sellAmountMax, data);

        assertEq(
            payAsset.balanceOf(scheduledPaymentAddr), payAmount, "scheduledPayment paid despite minimal-balance guard"
        );
        assertEq(fromAsset.balanceOf(address(vault)), 1 ether, "vault dropped below its minimal balance");
    }

    function test_payScheduledFromStaking_honoursTriggerRestriction() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockStakingProtocol impl = new MockStakingProtocol();
        address scheduledPaymentAddr = makeAddr("rentScheduledPayment");
        address trigger = makeAddr("trigger");

        _setupStakedReserve(usdc, impl, 1_000e6);

        vm.prank(ownerAddress);
        uint256 rentId = vault.addScheduledPayment(
            _makeScheduledPayment(
                scheduledPaymentAddr,
                trigger,
                address(usdc),
                250e6,
                3,
                block.timestamp,
                VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
                false
            )
        );

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ScheduledPaymentTriggerError.selector);
        vault.payScheduledFromStaking(rentId, address(impl));

        assertEq(usdc.balanceOf(scheduledPaymentAddr), 0);
        assertEq(IVaultFull(payable(address(vault))).getStakedBalance(address(impl), address(usdc)), 1_000e6);

        vm.prank(trigger);
        vault.payScheduledFromStaking(rentId, address(impl));
        assertEq(usdc.balanceOf(scheduledPaymentAddr), 250e6);
        assertEq(usdc.balanceOf(trigger), 0);
    }

    function test_payScheduledFromStaking_enforcesIntervalBetweenPayments() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockStakingProtocol impl = new MockStakingProtocol();
        address scheduledPaymentAddr = makeAddr("rentScheduledPayment");

        _setupStakedReserve(usdc, impl, 1_000e6);

        vm.prank(ownerAddress);
        uint256 rentId = vault.addScheduledPayment(
            _makeScheduledPayment(
                scheduledPaymentAddr,
                address(0),
                address(usdc),
                250e6,
                3,
                block.timestamp,
                VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
                false
            )
        );

        vault.payScheduledFromStaking(rentId, address(impl));

        vm.expectRevert(ScheduledPaymentInInterval.selector);
        vault.payScheduledFromStaking(rentId, address(impl));

        vm.warp(block.timestamp + VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL + 1);
        vault.payScheduledFromStaking(rentId, address(impl));
        assertEq(usdc.balanceOf(scheduledPaymentAddr), 500e6);
    }

    // ─── Unlimited scheduled payment ───────────────────────────────────────────

    function test_ScheduledPayment_maxPaymentCountIsUnlimited() public {
        _initializeVault();
        address to = makeAddr("unlimited");
        uint256 amount = 0.01 ether;
        uint256 start = block.timestamp;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            to,
            address(0),
            address(weth),
            amount,
            type(uint8).max,
            start,
            VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL,
            false
        );
        vm.prank(ownerAddress);
        uint256 uId = vault.addScheduledPayment(r);

        // Pay 260 times — well past the 255 uint8 ceiling. A decrementing count would revert at 256.
        uint256 payments = 260;
        deal(address(weth), address(vault), payments * amount);
        vault.payScheduled(uId);
        for (uint256 i = 1; i < payments; i++) {
            vm.warp(start + i * VaultLogic.SCHEDULED_PAYMENT_MINIMAL_INTERVAL);
            vault.payScheduled(uId);
        }
        assertEq(weth.balanceOf(to), payments * amount);
    }

    // ─── Whitelisted recipients ────────────────────────────────────────────────

    function test_WhitelistedRecipient_addAndGet() public {
        _initializeVault();
        address to = makeAddr("wlr");
        vm.prank(ownerAddress);
        uint256 bobIdWr = vault.addWhitelistedRecipient(to, address(weth));

        (address recipient, address allowedAsset) = vault.getWhitelistedRecipient(bobIdWr);
        assertEq(recipient, to);
        assertEq(allowedAsset, address(weth));
    }

    function test_WhitelistedRecipient_addRevertsOnZeroRecipient() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(AddressZero.selector);
        uint256 bobIdWr = vault.addWhitelistedRecipient(address(0), address(0));
    }

    function test_WhitelistedRecipient_updateChangesEntry() public {
        _initializeVault();
        address to1 = makeAddr("to1");
        address to2 = makeAddr("to2");
        vm.startPrank(ownerAddress);
        uint256 bobIdWr = vault.addWhitelistedRecipient(to1, address(weth));
        vault.updateWhitelistedRecipient(bobIdWr, to2, address(0));
        vm.stopPrank();

        (address recipient, address allowedAsset) = vault.getWhitelistedRecipient(bobIdWr);
        assertEq(recipient, to2);
        assertEq(allowedAsset, address(0));
    }

    function test_WhitelistedRecipient_updateRevertsWhenNotFound() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.updateWhitelistedRecipient(99999, makeAddr("to"), address(0));
    }

    function test_WhitelistedRecipient_anyAssetWhenAllowedAssetZero() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address to = makeAddr("wlr");
        vm.prank(ownerAddress);
        uint256 bobIdWr = vault.addWhitelistedRecipient(to, address(0));

        deal(address(weth), address(vault), 1 ether);
        usdc.mint(address(vault), 5_000e6);

        vm.startPrank(ownerAddress);
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1 ether);
        vault.sendToWhitelistedRecipient(bobIdWr, address(usdc), 5_000e6);
        vm.stopPrank();

        assertEq(weth.balanceOf(to), 1 ether);
        assertEq(usdc.balanceOf(to), 5_000e6);
    }

    function test_WhitelistedRecipient_sendRevertsOnZeroAmount() public {
        _initializeVault();
        address to = makeAddr("wlr");
        vm.prank(ownerAddress);
        uint256 wId = vault.addWhitelistedRecipient(to, address(weth));
        deal(address(weth), address(vault), 1 ether);

        vm.prank(ownerAddress);
        vm.expectRevert(AmountIsZero.selector);
        vault.sendToWhitelistedRecipient(wId, address(weth), 0);
    }

    function test_WhitelistedRecipient_restrictsToAllowedAsset() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address to = makeAddr("wlr");
        vm.prank(ownerAddress);
        uint256 bobIdWr = vault.addWhitelistedRecipient(to, address(weth));

        deal(address(weth), address(vault), 1 ether);
        usdc.mint(address(vault), 5_000e6);

        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientAssetNotAllowed.selector);
        vault.sendToWhitelistedRecipient(bobIdWr, address(usdc), 5_000e6);

        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_WhitelistedRecipient_revertsWhenNotFound() public {
        _initializeVault();
        deal(address(weth), address(vault), 1 ether);
        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.sendToWhitelistedRecipient(99999, address(weth), 1 ether);
    }

    function test_WhitelistedRecipient_remove() public {
        _initializeVault();
        address to = makeAddr("wlr");
        vm.startPrank(ownerAddress);
        uint256 bobIdWr = vault.addWhitelistedRecipient(to, address(0));
        vault.removeWhitelistedRecipient(bobIdWr);
        vm.stopPrank();

        (address recipient,) = vault.getWhitelistedRecipient(bobIdWr);
        assertEq(recipient, address(0));

        deal(address(weth), address(vault), 1 ether);
        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1 ether);
    }

    function test_WhitelistedRecipient_removeRevertsWhenNotFound() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.removeWhitelistedRecipient(99999);
    }

    function test_WhitelistedRecipient_onlyOwnerOrPaymentManager() public {
        _initializeVault();
        address stranger = makeAddr("stranger");
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        bytes32 pmRole = vault.PAYMENT_MANAGER_ROLE();

        vm.startPrank(stranger);
        // create/edit/remove are owner-or-payment-manager (a stranger is neither)
        vm.expectRevert(_roleError(stranger, pmRole));
        uint256 bobIdWr = vault.addWhitelistedRecipient(makeAddr("to"), address(0));
        vm.expectRevert(_roleError(stranger, pmRole));
        vault.updateWhitelistedRecipient(bobIdWr, makeAddr("to"), address(0));
        vm.expectRevert(_roleError(stranger, pmRole));
        vault.removeWhitelistedRecipient(bobIdWr);
        // paying out stays strictly owner-only
        vm.expectRevert(_roleError(stranger, adminRole));
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1);
        vm.stopPrank();
    }

    // ─── New-address protection shared by scheduled payments and whitelisted recipients ─────────

    function test_WhitelistedRecipient_protectionBlocksThenAllowsAfterWindow() public {
        _initializeVault();
        uint256 protection = 3 days;
        address to = makeAddr("wlr");

        vm.startPrank(ownerAddress);
        vault.setNewAddressProtection(protection);
        uint256 bobIdWr = vault.addWhitelistedRecipient(to, address(weth));
        vm.stopPrank();

        deal(address(weth), address(vault), 1 ether);

        vm.prank(ownerAddress);
        vm.expectRevert(AddressProtectionNotEnded.selector);
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1 ether);

        vm.warp(block.timestamp + protection);
        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    // Regression: the address-keyed protection deadline is shared, so removing one of two entries
    // pointing at the same address must NOT clear the lock for the remaining one.
    function test_AddressProtection_notBypassableViaTwoWhitelistNames() public {
        _initializeVault();
        uint256 protection = 7 days;
        address payee = makeAddr("payee");
        deal(address(weth), address(vault), 1 ether);

        vm.startPrank(ownerAddress);
        vault.setNewAddressProtection(protection);
        uint256 aIdWr = vault.addWhitelistedRecipient(payee, address(0));
        uint256 bIdWr = vault.addWhitelistedRecipient(payee, address(0)); // same payee, second entry
        vault.removeWhitelistedRecipient(bIdWr); // must not clear the shared lock for aIdWr
        vm.expectRevert(AddressProtectionNotEnded.selector);
        vault.sendToWhitelistedRecipient(aIdWr, address(weth), 1 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + protection);
        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(aIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(payee), 1 ether);
    }

    // Regression: same bypass across features (scheduled payment + whitelist on one address).
    function test_AddressProtection_notBypassableCrossFeature() public {
        _initializeVault();
        uint256 protection = 7 days;
        address payee = makeAddr("payee");
        deal(address(weth), address(vault), 1 ether);

        vm.startPrank(ownerAddress);
        vault.setNewAddressProtection(protection);
        uint256 wlIdWr = vault.addWhitelistedRecipient(payee, address(0));
        IBittyV1Vault.ScheduledPayment memory sp =
            _makeScheduledPayment(payee, address(0), address(weth), 0.1 ether, 1, block.timestamp, 0, false);
        uint256 spId = vault.addScheduledPayment(sp);
        vault.removeScheduledPayment(spId); // must not clear protection[payee]
        vm.expectRevert(AddressProtectionNotEnded.selector);
        vault.sendToWhitelistedRecipient(wlIdWr, address(weth), 1 ether);
        vm.stopPrank();
    }

    function test_WhitelistedRecipient_noProtectionWhenDisabled() public {
        _initializeVault();
        address to = makeAddr("wlr");
        vm.prank(ownerAddress);
        uint256 bobIdWr = vault.addWhitelistedRecipient(to, address(weth));

        deal(address(weth), address(vault), 1 ether);
        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_WhitelistedRecipient_removeClearsProtectionAndReAddReArms() public {
        _initializeVault();
        uint256 protection = 2 days;
        address to = makeAddr("wlr");

        vm.startPrank(ownerAddress);
        vault.setNewAddressProtection(protection);
        uint256 bobIdWr = vault.addWhitelistedRecipient(to, address(weth));
        vault.removeWhitelistedRecipient(bobIdWr);
        // Re-adding arms a fresh window from now.
        bobIdWr = vault.addWhitelistedRecipient(to, address(weth));
        vm.stopPrank();

        deal(address(weth), address(vault), 1 ether);

        vm.prank(ownerAddress);
        vm.expectRevert(AddressProtectionNotEnded.selector);
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1 ether);

        vm.warp(block.timestamp + protection);
        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_AddressProtection_protectedScheduledAddressCannotBePaidViaWhitelist() public {
        _initializeVault();
        uint256 protection = 5 days;
        address shared = makeAddr("sharedPayee");

        vm.prank(ownerAddress);
        vault.setNewAddressProtection(protection);

        // Introduce `shared` as a scheduled payment — it is time-locked.
        IBittyV1Vault.ScheduledPayment memory r =
            _makeScheduledPayment(shared, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        uint256 aliceId = vault.addScheduledPayment(r);

        // Whitelisting the SAME address under a new name does not escape the shared lock.
        vm.prank(ownerAddress);
        uint256 bobIdWr = vault.addWhitelistedRecipient(shared, address(weth));

        deal(address(weth), address(vault), 2 ether);

        vm.prank(ownerAddress);
        vm.expectRevert(AddressProtectionNotEnded.selector);
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1 ether);

        // The scheduled path is blocked too.
        vm.expectRevert(AddressProtectionNotEnded.selector);
        vault.payScheduled(aliceId);

        // After the window both paths are payable.
        vm.warp(block.timestamp + protection);
        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1 ether);
        vault.payScheduled(aliceId);
        assertEq(weth.balanceOf(shared), 2 ether);
    }

    function test_AddressProtection_reIntroducingLaterOnlyExtendsSharedLock() public {
        _initializeVault();
        uint256 protection = 10 days;
        address shared = makeAddr("sharedPayee");
        // Use a fixed literal base rather than a `block.timestamp`-derived local: under via_ir such a
        // local can be re-aliased to the timestamp opcode and re-read after warps, corrupting the math.
        uint256 base = 1_000_000;
        vm.warp(base);

        vm.startPrank(ownerAddress);
        vault.setNewAddressProtection(protection);
        IBittyV1Vault.ScheduledPayment memory r =
            _makeScheduledPayment(shared, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        uint256 aliceId = vault.addScheduledPayment(r);
        vm.stopPrank();
        // Scheduled add arms the shared lock: unlocks at base + 10d.

        // Re-introduce the same address via whitelist 3 days later: the shared lock is pushed out
        // (max), never pulled in, so it now unlocks at the later deadline (base + 3d + 10d = base + 13d).
        vm.warp(base + 3 days);
        vm.prank(ownerAddress);
        uint256 bobIdWr = vault.addWhitelistedRecipient(shared, address(weth));

        deal(address(weth), address(vault), 1 ether);

        // Past the original 10-day deadline but before the extended 13-day one — still blocked.
        vm.warp(base + 10 days + 1);
        vm.prank(ownerAddress);
        vm.expectRevert(AddressProtectionNotEnded.selector);
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1 ether);

        // After the extended deadline — payable.
        vm.warp(base + 13 days);
        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(bobIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(shared), 1 ether);
    }

    // ─── Payment manager: propose → owner approve ───────────────────────────────

    function _grantPaymentManager(address pm) internal {
        bytes32 role = vault.PAYMENT_MANAGER_ROLE();
        vm.prank(ownerAddress);
        vault.grantRole(role, pm);
    }

    function _spTo(address to) internal view returns (IBittyV1Vault.ScheduledPayment memory) {
        return _makeScheduledPayment(to, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
    }

    function test_PaymentManager_scheduledPendingUntilApproved() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        address to = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);

        vm.prank(pm);
        uint256 pId = vault.addScheduledPayment(_spTo(to));

        vm.expectRevert(PaymentNotApproved.selector);
        vault.payScheduled(pId);

        vm.prank(ownerAddress);
        vault.approveScheduledPayment(pId);
        vault.payScheduled(pId);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_PaymentManager_ownerCreatedIsAutoApproved() public {
        _initializeVault();
        address to = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);
        vm.prank(ownerAddress);
        uint256 pId = vault.addScheduledPayment(_spTo(to));
        vault.payScheduled(pId);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_PaymentManager_whitelistedPendingUntilApproved() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        address to = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);

        vm.prank(pm);
        uint256 wIdWr = vault.addWhitelistedRecipient(to, address(0));

        vm.prank(ownerAddress);
        vm.expectRevert(PaymentNotApproved.selector);
        vault.sendToWhitelistedRecipient(wIdWr, address(weth), 1 ether);

        vm.prank(ownerAddress);
        vault.approveWhitelistedRecipient(wIdWr);
        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(wIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_PaymentManager_sendProposalThenApprove() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        address to = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);

        vm.prank(pm);
        vault.send(to, address(weth), 1 ether); // proposal id 0, no transfer
        assertEq(weth.balanceOf(to), 0);

        vm.prank(ownerAddress);
        vault.approveSend(0);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_PaymentManager_ownerSendIsImmediate() public {
        _initializeVault();
        address to = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);
        vm.prank(ownerAddress);
        vault.send(to, address(weth), 1 ether);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_PaymentManager_cancelOwnSendNotOthers() public {
        _initializeVault();
        address pm = makeAddr("pm");
        address pm2 = makeAddr("pm2");
        _grantPaymentManager(pm);
        _grantPaymentManager(pm2);
        deal(address(weth), address(vault), 10 ether);

        vm.prank(pm);
        vault.send(makeAddr("payee"), address(weth), 1 ether); // id 0

        vm.prank(pm2);
        vm.expectRevert(NotProposalOwner.selector);
        vault.cancelSend(0);

        vm.prank(pm);
        vault.cancelSend(0);

        vm.prank(ownerAddress);
        vm.expectRevert(PendingSendNotFound.selector);
        vault.approveSend(0);
    }

    function test_PaymentManager_cannotEditOrRemoveApprovedEntry() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        IBittyV1Vault.ScheduledPayment memory r = _spTo(makeAddr("payee"));
        vm.prank(ownerAddress);
        uint256 pId = vault.addScheduledPayment(r); // owner-created = approved

        r.amount = 2 ether;
        vm.prank(pm);
        vm.expectRevert(NotProposalOwner.selector);
        vault.updateScheduledPayment(pId, r);

        vm.prank(pm);
        vm.expectRevert(NotProposalOwner.selector);
        vault.removeScheduledPayment(pId);
    }

    function test_PaymentManager_cancelOwnPendingScheduled() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        vm.prank(pm);
        uint256 pId = vault.addScheduledPayment(_spTo(makeAddr("payee")));
        vm.prank(pm);
        vault.removeScheduledPayment(pId);

        vm.expectRevert(ScheduledPaymentNotFound.selector);
        vault.payScheduled(pId);
    }

    function test_PaymentManager_onlyOwnerApproves() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        vm.prank(pm);
        uint256 pId = vault.addScheduledPayment(_spTo(makeAddr("payee")));

        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(pm);
        vm.expectRevert(_roleError(pm, adminRole));
        vault.approveScheduledPayment(pId);
    }

    function test_PaymentManager_approveNonPendingReverts() public {
        _initializeVault();
        vm.prank(ownerAddress);
        uint256 pId = vault.addScheduledPayment(_spTo(makeAddr("payee"))); // auto-approved

        vm.prank(ownerAddress);
        vm.expectRevert(NotPendingApproval.selector);
        vault.approveScheduledPayment(pId);
    }

    function test_PaymentManager_proposeSendRevertsWhenSendingDisabled() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        vm.prank(ownerAddress);
        vault.disableSending();
        vm.prank(pm);
        vm.expectRevert(SendingDisabled.selector);
        vault.send(makeAddr("payee"), address(weth), 1 ether);
    }

    function test_PaymentManager_approveSendRevertsIfSendingDisabledAfterPropose() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        deal(address(weth), address(vault), 10 ether);
        vm.prank(pm);
        vault.send(makeAddr("payee"), address(weth), 1 ether); // id 0
        vm.prank(ownerAddress);
        vault.disableSending();
        vm.prank(ownerAddress);
        vm.expectRevert(SendingDisabled.selector);
        vault.approveSend(0);
    }

    function test_PaymentManager_ownerCancelsPendingSend() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        deal(address(weth), address(vault), 10 ether);
        vm.prank(pm);
        vault.send(makeAddr("payee"), address(weth), 1 ether); // id 0
        vm.prank(ownerAddress);
        vault.cancelSend(0); // owner cancels a manager's proposal
        vm.prank(ownerAddress);
        vm.expectRevert(PendingSendNotFound.selector);
        vault.approveSend(0);
    }

    function test_PaymentManager_managerEditsOwnPendingScheduled() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        address to = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);
        vm.prank(pm);
        uint256 pId = vault.addScheduledPayment(_spTo(to));

        IBittyV1Vault.ScheduledPayment memory r2 = _spTo(to);
        r2.amount = 2 ether;
        vm.prank(pm);
        vault.updateScheduledPayment(pId, r2); // manager edits its own still-pending proposal

        vm.expectRevert(PaymentNotApproved.selector);
        vault.payScheduled(pId);

        vm.prank(ownerAddress);
        vault.approveScheduledPayment(pId);
        vault.payScheduled(pId);
        assertEq(weth.balanceOf(to), 2 ether);
    }

    function test_PaymentManager_managerEditsOwnPendingWhitelisted() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        address to2 = makeAddr("payee2");
        deal(address(weth), address(vault), 10 ether);
        vm.prank(pm);
        uint256 wIdWr = vault.addWhitelistedRecipient(makeAddr("payee"), address(0));
        vm.prank(pm);
        vault.updateWhitelistedRecipient(wIdWr, to2, address(weth)); // edit own pending

        vm.prank(ownerAddress);
        vault.approveWhitelistedRecipient(wIdWr);
        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(wIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(to2), 1 ether);
    }

    function test_PaymentManager_managerCannotTouchApprovedWhitelisted() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        address to = makeAddr("payee");
        vm.prank(ownerAddress);
        uint256 wIdWr = vault.addWhitelistedRecipient(to, address(0)); // approved

        vm.prank(pm);
        vm.expectRevert(NotProposalOwner.selector);
        vault.updateWhitelistedRecipient(wIdWr, to, address(weth));
        vm.prank(pm);
        vm.expectRevert(NotProposalOwner.selector);
        vault.removeWhitelistedRecipient(wIdWr);
    }

    function test_PaymentManager_managerCancelsOwnPendingWhitelisted() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        vm.prank(pm);
        uint256 wIdWr = vault.addWhitelistedRecipient(makeAddr("payee"), address(0));
        vm.prank(pm);
        vault.removeWhitelistedRecipient(wIdWr); // cancel own pending
        (address r,) = vault.getWhitelistedRecipient(wIdWr);
        assertEq(r, address(0));
    }

    function test_PaymentManager_approveScheduledNotFound() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(ScheduledPaymentNotFound.selector);
        vault.approveScheduledPayment(99999);
    }

    function test_PaymentManager_approveWhitelistedNotFoundAndNotPending() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.approveWhitelistedRecipient(99999);

        vm.prank(ownerAddress);
        uint256 wIdWr = vault.addWhitelistedRecipient(makeAddr("to"), address(0)); // owner-created = approved
        vm.prank(ownerAddress);
        vm.expectRevert(NotPendingApproval.selector);
        vault.approveWhitelistedRecipient(wIdWr);
    }

    function test_PaymentManager_cancelSendNotFound() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(PendingSendNotFound.selector);
        vault.cancelSend(42);
    }

    function test_Send_ownerRevertsWhenSendingDisabled() public {
        _initializeVault();
        deal(address(weth), address(vault), 10 ether);
        vm.prank(ownerAddress);
        vault.disableSending();
        vm.prank(ownerAddress);
        vm.expectRevert(SendingDisabled.selector);
        vault.send(makeAddr("payee"), address(weth), 1 ether);
    }

    function test_IsSendingDisabled_returnsTrueAfterDisable() public {
        _initializeVault();
        assertFalse(vault.isSendingDisabled());
        vm.prank(ownerAddress);
        vault.disableSending();
        assertTrue(vault.isSendingDisabled());
    }

    function test_WhitelistedRecipient_updateZeroRecipientReverts() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(AddressZero.selector);
        vault.updateWhitelistedRecipient(99999, address(0), address(0));
    }

    // Fund the vault with real (ETH-backed) WETH so unwrap-to-ETH works, unlike a bare `deal`.
    function _fundVaultWeth(uint256 amount) internal {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.transfer(address(vault), amount);
    }

    // ─── ETH payouts (asset address(0) = pay native ETH) ────────────────────────

    function test_ETH_ownerSendUnwrapsWethToNativeEth() public {
        _initializeVault();
        _fundVaultWeth(5 ether);
        address to = makeAddr("payee");
        assertEq(to.balance, 0);

        vm.prank(ownerAddress);
        vault.send(to, address(0), 2 ether);

        assertEq(to.balance, 2 ether);
        assertEq(weth.balanceOf(address(vault)), 3 ether);
    }

    function test_ETH_scheduledPaysNativeEth() public {
        _initializeVault();
        _fundVaultWeth(5 ether);
        address to = makeAddr("payee");
        vm.prank(ownerAddress);
        uint256 pId = vault.addScheduledPayment(
            _makeScheduledPayment(to, address(0), address(0), 1 ether, 1, block.timestamp, 0, false)
        );

        vault.payScheduled(pId);
        assertEq(to.balance, 1 ether);
        assertEq(weth.balanceOf(address(vault)), 4 ether);
    }

    function test_ETH_scheduledPartialPayWithInsufficientBalance() public {
        _initializeVault();
        _fundVaultWeth(0.4 ether); // less than the 1 ETH scheduled
        address to = makeAddr("payee");
        IBittyV1Vault.ScheduledPayment memory r =
            _makeScheduledPayment(to, address(0), address(0), 1 ether, 1, block.timestamp, 0, false);
        r.payWithInsufficientBalance = true;
        vm.prank(ownerAddress);
        uint256 pId = vault.addScheduledPayment(r);

        vault.payScheduled(pId);
        assertEq(to.balance, 0.4 ether); // paid what the vault had
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    function test_ETH_whitelistedPaysNativeEth() public {
        _initializeVault();
        _fundVaultWeth(5 ether);
        address to = makeAddr("payee");
        vm.prank(ownerAddress);
        uint256 wIdWr = vault.addWhitelistedRecipient(to, address(0)); // allowedAsset = any

        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(wIdWr, address(0), 2 ether);
        assertEq(to.balance, 2 ether);
    }

    function test_ETH_paymentManagerSendProposalPaysEth() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _grantPaymentManager(pm);
        _fundVaultWeth(5 ether);
        address to = makeAddr("payee");

        vm.prank(pm);
        vault.send(to, address(0), 2 ether); // proposal, no transfer
        assertEq(to.balance, 0);

        vm.prank(ownerAddress);
        vault.approveSend(0);
        assertEq(to.balance, 2 ether);
    }

    function test_ETH_scheduledFromStakingDeliversWeth() public {
        _initializeVault();
        MockStakingProtocol impl = new MockStakingProtocol();
        address to = makeAddr("payee");

        vm.prank(ownerAddress);
        BittyV1Guard(guardAddress).addStakingProtocols(_arr(address(impl)));
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).addStakingProtocols(_arr(address(impl)));
        _fundVaultWeth(5 ether);
        vm.prank(assetManagerAddress);
        IVaultFull(payable(address(vault))).stake(address(impl), address(weth), 5 ether);

        // ETH scheduled payment (asset address(0))
        vm.prank(ownerAddress);
        uint256 pId = vault.addScheduledPayment(
            _makeScheduledPayment(to, address(0), address(0), 1 ether, 1, block.timestamp, 0, false)
        );

        vault.payScheduledFromStaking(pId, address(impl));
        // Yield-delivery paths deliver WETH, not native ETH.
        assertEq(weth.balanceOf(to), 1 ether);
        assertEq(to.balance, 0);
    }

    function test_ETH_reentrantRecipientCannotDoublePay() public {
        _initializeVault();
        _fundVaultWeth(5 ether);
        ReentrantEthReceiver attacker = new ReentrantEthReceiver();

        vm.startPrank(ownerAddress);
        uint256 pId = vault.addScheduledPayment(
            _makeScheduledPayment(address(attacker), address(0), address(0), 1 ether, 1, block.timestamp, 0, false)
        );
        uint256 qId = vault.addScheduledPayment(
            _makeScheduledPayment(address(attacker), address(0), address(0), 1 ether, 1, block.timestamp, 0, false)
        );
        vm.stopPrank();
        // Reentering a *different*, independently-due ETH payment reaches _payOut while payingEth is
        // still set, so the reentry hits the ReentrantCall guard instead of double-paying.
        attacker.arm(vault, qId);

        vault.payScheduled(pId);
        // "p" paid once; the reentrant "q" payout reverted and was swallowed, so it never sent.
        assertEq(address(attacker).balance, 1 ether);
        assertEq(weth.balanceOf(address(vault)), 4 ether);
    }

    function test_ETH_paymentToRejectingRecipientReverts() public {
        _initializeVault();
        _fundVaultWeth(5 ether);
        RejectEthReceiver rejecter = new RejectEthReceiver();

        vm.prank(ownerAddress);
        uint256 pId = vault.addScheduledPayment(
            _makeScheduledPayment(address(rejecter), address(0), address(0), 1 ether, 1, block.timestamp, 0, false)
        );

        vm.expectRevert(TransferFailed.selector);
        vault.payScheduled(pId);
    }
}
