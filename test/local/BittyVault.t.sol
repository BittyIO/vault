// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {BittyVault} from "../../src/BittyVault.sol";
import {VaultLogic} from "../../src/logic/VaultLogic.sol";
import {
    IVault,
    AmountIsZero,
    ReceiverNotFound,
    ReceiverNameAlreadyExists,
    ReceiverImmutable,
    ReceiverPaymentCountZero,
    ReceiverDurationTooShort,
    NewReceiverProtectionOutOfRange,
    ReceiverProtectionNotEnded,
    OnlyReceiver,
    ReceiverNotStartYet,
    PayMoreThanReceiverAmount,
    PayReceiverAmountTriggerEmpty,
    InsufficientBalance,
    OwnerAndAssetManagerMustDiffer
} from "../../src/interfaces/IVault.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {BittyGuard} from "guard-contracts/src/BittyGuard.sol";

contract BittyVaultTest is Test {
    BittyVault public vault;
    WETH public weth;
    address public guardAddress;
    address public ownerAddress;
    address public assetManagerAddress;

    function setUp() public {
        weth = new WETH();
        vault = new BittyVault();
        guardAddress = address(new BittyGuard());
        ownerAddress = tx.origin;
        assetManagerAddress = makeAddr("assetManager");
    }

    function _roleError(address account, bytes32 role) internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "AccessControl: account ",
                Strings.toHexString(uint160(account), 20),
                " is missing role ",
                Strings.toHexString(uint256(role), 32)
            )
        );
    }

    function _makeReceiver(
        address receiverAddress_,
        address trigger_,
        address assetAddress_,
        uint256 amount_,
        uint8 paymentCount_,
        uint256 startTimestamp_,
        uint256 durationTimestamp_,
        bool isImmutable_
    ) internal pure returns (IVault.Receiver memory) {
        return IVault.Receiver({
            receiverAddress: receiverAddress_,
            trigger: trigger_,
            assetAddress: assetAddress_,
            amount: amount_,
            paymentCount: paymentCount_,
            startTimestamp: startTimestamp_,
            durationTimestamp: durationTimestamp_,
            isImmutable: isImmutable_
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
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );

        address depositor = makeAddr("ethDepositor");
        uint256 amount = 0.05 ether;

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success,) = address(vault).call{value: amount}("");

        assertTrue(success);
        assertEq(address(vault).balance, amount);
    }

    function test_InitErrorOwnerAndAssetManagerSameAddress() public {
        vm.expectRevert(OwnerAndAssetManagerMustDiffer.selector);
        vault.initialize(
            ownerAddress,
            "test vault",
            ownerAddress, // assetManager == owner — must revert
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_InitSucceedsWithDifferentAssetManager() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        assertTrue(vault.hasRole(vault.ASSET_MANAGER_ROLE(), assetManagerAddress));
    }

    function test_GrantRoleRevertsIfOwnerGrantsAssetManagerRoleToSelf() public {
        _initializeVault();
        bytes32 assetManagerRole = vault.ASSET_MANAGER_ROLE();
        vm.prank(ownerAddress);
        vm.expectRevert(OwnerAndAssetManagerMustDiffer.selector);
        vault.grantRole(assetManagerRole, ownerAddress);
    }

    function test_GrantRoleRevertsIfAssetManagerGrantedAdminRole() public {
        address assetMgr = makeAddr("assetMgr");
        vault.initialize(
            ownerAddress,
            "test vault",
            assetMgr,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(ownerAddress);
        vm.expectRevert(OwnerAndAssetManagerMustDiffer.selector);
        vault.grantRole(adminRole, assetMgr);
    }

    function test_InitErrorWithAlreadyInitialized() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        vm.expectRevert("Initializable: contract is already initialized");
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_AddReceiverSuccess() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        address receiverAddr = makeAddr("receiver");
        IVault.Receiver memory r =
            _makeReceiver(receiverAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);
    }

    function test_AddReceiverRevertDuplicateName() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false);
        vm.startPrank(ownerAddress);
        vault.addReceiver("alice", r);
        vm.expectRevert(ReceiverNameAlreadyExists.selector);
        vault.addReceiver("alice", r);
        vm.stopPrank();
    }

    function test_AddReceiverSuccessSameNameAfterRemoveReceiver() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false);
        vm.startPrank(ownerAddress);
        vault.addReceiver("alice", r);
        vault.removeReceiver("alice");
        vault.addReceiver("alice", r);
        vm.stopPrank();
    }

    function test_AddReceiverRevertUnauthorized() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false);
        bytes32 _receiverRole = vault.DEFAULT_ADMIN_ROLE();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, _receiverRole));
        vault.addReceiver("alice", r);
    }

    function test_AddReceiverRevertAmountZero() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 0, 1, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        vm.expectRevert(AmountIsZero.selector);
        vault.addReceiver("alice", r);
    }

    function test_AddReceiverRevertPaymentCountZero() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 1 ether, 0, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        vm.expectRevert(ReceiverPaymentCountZero.selector);
        vault.addReceiver("alice", r);
    }

    function test_AddReceiverRevertDurationTooShortWhenPaymentCountGreaterThanOne() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r = _makeReceiver(
            makeAddr("receiver"),
            address(0),
            address(weth),
            1 ether,
            2,
            block.timestamp,
            VaultLogic.RECEIVER_MINIMAL_DURATION - 1,
            false
        );
        vm.prank(ownerAddress);
        vm.expectRevert(ReceiverDurationTooShort.selector);
        vault.addReceiver("alice", r);
    }

    function test_AddReceiverSuccessWithShortDurationWhenPaymentCountIsOne() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);
    }

    function test_UpdateReceiverRevertDurationTooShortWhenPaymentCountGreaterThanOne() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r = _makeReceiver(
            makeAddr("receiver"),
            address(0),
            address(weth),
            1 ether,
            2,
            block.timestamp,
            VaultLogic.RECEIVER_MINIMAL_DURATION,
            false
        );
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);

        r.durationTimestamp = VaultLogic.RECEIVER_MINIMAL_DURATION - 1;
        vm.prank(ownerAddress);
        vm.expectRevert(ReceiverDurationTooShort.selector);
        vault.updateReceiver("alice", r);
    }

    function test_UpdateReceiverSuccessWithShortDurationWhenPaymentCountIsOne() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r = _makeReceiver(
            makeAddr("receiver"),
            address(0),
            address(weth),
            1 ether,
            2,
            block.timestamp,
            VaultLogic.RECEIVER_MINIMAL_DURATION,
            false
        );
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);

        r.paymentCount = 1;
        r.durationTimestamp = 0;
        vm.prank(ownerAddress);
        vault.updateReceiver("alice", r);
    }

    function test_UpdateReceiverSuccess() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        address receiverAddr = makeAddr("receiver");
        IVault.Receiver memory r =
            _makeReceiver(receiverAddr, address(0), address(weth), 1 ether, 2, block.timestamp, 1 days, false);
        vm.startPrank(ownerAddress);
        vault.addReceiver("alice", r);
        r.amount = 2 ether;
        vault.updateReceiver("alice", r);
        vm.stopPrank();
    }

    function test_UpdateReceiverRevertNotFound() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false);
        vm.prank(ownerAddress);
        vm.expectRevert(ReceiverNotFound.selector);
        vault.updateReceiver("nonexistent", r);
    }

    function test_UpdateReceiverRevertImmutable() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, true);
        vm.startPrank(ownerAddress);
        vault.addReceiver("alice", r);
        r.amount = 2 ether;
        vm.expectRevert(ReceiverImmutable.selector);
        vault.updateReceiver("alice", r);
        vm.stopPrank();
    }

    function test_UpdateReceiverRevertOnlyOwner() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);
        r.amount = 2 ether;
        bytes32 _receiverRole = vault.DEFAULT_ADMIN_ROLE();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, _receiverRole));
        vault.updateReceiver("alice", r);
    }

    function test_RemoveReceiverSuccess() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false);
        vm.startPrank(ownerAddress);
        vault.addReceiver("alice", r);
        vault.removeReceiver("alice");
        vm.stopPrank();
        vm.expectRevert(ReceiverNotFound.selector);
        vault.payReceiver("alice");
    }

    function test_RemoveReceiverRevertOnlyOwner() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);
        bytes32 _receiverRole = vault.DEFAULT_ADMIN_ROLE();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, _receiverRole));
        vault.removeReceiver("alice");
    }

    function test_ChangeReceiverAddressSuccess() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        IVault.Receiver memory r =
            _makeReceiver(alice, address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);
        vm.prank(alice);
        vault.changeReceiverAddress("alice", bob);
    }

    function test_ChangeReceiverAddressRevertReceiverNotFound() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        vm.expectRevert(ReceiverNotFound.selector);
        vault.changeReceiverAddress("nonexistent", makeAddr("attacker"));
    }

    function test_ChangeReceiverAddressRevertOnlyReceiver() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        IVault.Receiver memory r =
            _makeReceiver(alice, address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(OnlyReceiver.selector);
        vault.changeReceiverAddress("alice", bob);
    }

    function test_ChangeReceiverAddressRevertReceiverImmutable() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        IVault.Receiver memory r =
            _makeReceiver(alice, address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, true);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);
        vm.prank(alice);
        vm.expectRevert(ReceiverImmutable.selector);
        vault.changeReceiverAddress("alice", bob);
    }

    function test_PayReceiver_revertReceiverNotStartYet() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        uint256 futureStartTimestamp = block.timestamp + 100;
        IVault.Receiver memory r = _makeReceiver(
            makeAddr("receiver"), address(0), address(weth), 1 ether, 1, futureStartTimestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);

        vm.expectRevert(ReceiverNotStartYet.selector);
        vault.payReceiver("alice");
    }

    function test_PayReceiver_singlePaymentWithZeroDuration() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        address receiverAddr = makeAddr("receiver");
        IVault.Receiver memory r =
            _makeReceiver(receiverAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);

        deal(address(weth), address(vault), 1 ether);

        vault.payReceiver("alice");
        assertEq(weth.balanceOf(receiverAddr), 1 ether);

        vm.expectRevert(ReceiverPaymentCountZero.selector);
        vault.payReceiver("alice");
    }

    function test_PayReceiver_receiverStorageUpdatedSoPaymentCountEnforced() public {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        address receiverAddr = makeAddr("receiver");
        vm.warp(1000);
        IVault.Receiver memory r = _makeReceiver(
            receiverAddr,
            address(0),
            address(weth),
            1 ether,
            2,
            block.timestamp,
            VaultLogic.RECEIVER_MINIMAL_DURATION,
            false
        );
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);

        deal(address(weth), address(vault), 2 ether);

        vault.payReceiver("alice");
        vm.warp(block.timestamp + VaultLogic.RECEIVER_MINIMAL_DURATION);
        vault.payReceiver("alice");

        assertEq(weth.balanceOf(receiverAddr), 2 ether, "receiver should have received 2 payments");

        vm.expectRevert(ReceiverPaymentCountZero.selector);
        vault.payReceiver("alice");
    }

    function test_SetNewReceiverProtectionRevertUnauthorizedWhenNotInitialized() public {
        vm.expectRevert(); // no roles granted before initialize, AccessControl fires first
        vault.setNewReceiverProtection(1 days);
    }

    function test_SetNewReceiverProtectionRevertUnauthorized() public {
        _initializeVault();
        bytes32 _adminRole = vault.DEFAULT_ADMIN_ROLE();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, _adminRole));
        vault.setNewReceiverProtection(1 days);
    }

    function test_SetNewReceiverProtectionRevertOutOfRange() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(NewReceiverProtectionOutOfRange.selector);
        vault.setNewReceiverProtection(VaultLogic.RECEIVER_NEW_PROTECTION_MAX + 1);
    }

    function test_SetNewReceiverProtectionSuccessAtMax() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vault.setNewReceiverProtection(VaultLogic.RECEIVER_NEW_PROTECTION_MAX);
    }

    function test_PayReceiver_revertReceiverProtectionNotEnded() public {
        _initializeVault();
        uint256 protection = 3 days;
        vm.prank(ownerAddress);
        vault.setNewReceiverProtection(protection);

        address receiverAddr = makeAddr("receiver");
        IVault.Receiver memory r =
            _makeReceiver(receiverAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);

        deal(address(weth), address(vault), 1 ether);

        vm.expectRevert(ReceiverProtectionNotEnded.selector);
        vault.payReceiver("alice");
    }

    function test_PayReceiver_successAfterReceiverProtectionEnds() public {
        _initializeVault();
        uint256 protection = 3 days;
        vm.prank(ownerAddress);
        vault.setNewReceiverProtection(protection);

        address receiverAddr = makeAddr("receiver");
        uint256 addedAt = block.timestamp;
        IVault.Receiver memory r =
            _makeReceiver(receiverAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);

        deal(address(weth), address(vault), 1 ether);

        vm.warp(addedAt + protection);
        vault.payReceiver("alice");
        assertEq(weth.balanceOf(receiverAddr), 1 ether);
    }

    function test_PayReceiver_noProtectionWhenProtectionIsZero() public {
        _initializeVault();
        address receiverAddr = makeAddr("receiver");
        IVault.Receiver memory r =
            _makeReceiver(receiverAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);

        deal(address(weth), address(vault), 1 ether);

        vault.payReceiver("alice");
        assertEq(weth.balanceOf(receiverAddr), 1 ether);
    }

    function test_PayReceiver_protectionOnlyAppliesToReceiversAddedWhileEnabled() public {
        _initializeVault();
        address aliceReceiver = makeAddr("aliceReceiver");
        address bobReceiver = makeAddr("bobReceiver");

        vm.prank(ownerAddress);
        vault.setNewReceiverProtection(2 days);

        IVault.Receiver memory alice =
            _makeReceiver(aliceReceiver, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", alice);

        vm.prank(ownerAddress);
        vault.setNewReceiverProtection(0);

        IVault.Receiver memory bob =
            _makeReceiver(bobReceiver, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        vault.addReceiver("bob", bob);

        deal(address(weth), address(vault), 2 ether);

        vm.expectRevert(ReceiverProtectionNotEnded.selector);
        vault.payReceiver("alice");

        vault.payReceiver("bob");
        assertEq(weth.balanceOf(bobReceiver), 1 ether);
    }

    function test_RemoveReceiver_clearsProtectionSoReAddCanPayAfterProtection() public {
        _initializeVault();
        uint256 protection = 1 days;
        address receiverAddr = makeAddr("receiver");

        vm.prank(ownerAddress);
        vault.setNewReceiverProtection(protection);

        IVault.Receiver memory r =
            _makeReceiver(receiverAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        vm.startPrank(ownerAddress);
        vault.addReceiver("alice", r);
        vault.removeReceiver("alice");
        vault.addReceiver("alice", r);
        vm.stopPrank();

        deal(address(weth), address(vault), 1 ether);

        vm.expectRevert(ReceiverProtectionNotEnded.selector);
        vault.payReceiver("alice");

        vm.warp(block.timestamp + protection);
        vault.payReceiver("alice");
        assertEq(weth.balanceOf(receiverAddr), 1 ether);
    }

    function test_PayReceiverAmount_revertTriggerEmpty() public {
        _initializeVault();
        address receiverAddr = makeAddr("receiver");
        _addReceiver("alice", receiverAddr, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.expectRevert(PayReceiverAmountTriggerEmpty.selector);
        vault.payReceiverAmount("alice", 1 ether);
    }

    function test_PayReceiverAmount_successWhenAmountEqualsReceiverAmount() public {
        _initializeVault();
        address receiverAddr = makeAddr("receiver");
        address trigger = makeAddr("trigger");
        _addReceiverWithTrigger("alice", receiverAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vault.payReceiverAmount("alice", 1 ether);
        assertEq(weth.balanceOf(receiverAddr), 1 ether);

        vm.prank(trigger);
        vm.expectRevert(ReceiverPaymentCountZero.selector);
        vault.payReceiverAmount("alice", 1 ether);
    }

    function test_PayReceiverAmount_successWhenAmountLessThanReceiverAmount() public {
        _initializeVault();
        address receiverAddr = makeAddr("receiver");
        address trigger = makeAddr("trigger");
        _addReceiverWithTrigger("alice", receiverAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vault.payReceiverAmount("alice", 0.5 ether);
        assertEq(weth.balanceOf(receiverAddr), 1 ether, "transfers full configured receiver amount");
    }

    function test_PayReceiverAmount_revertPayMoreThanReceiverAmount() public {
        _initializeVault();
        address receiverAddr = makeAddr("receiver");
        address trigger = makeAddr("trigger");
        _addReceiverWithTrigger("alice", receiverAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectRevert(PayMoreThanReceiverAmount.selector);
        vault.payReceiverAmount("alice", 1 ether + 1);
    }

    function test_PayReceiverAmount_revertReceiverNotStartYet() public {
        _initializeVault();
        uint256 futureStart = block.timestamp + 100;
        address receiverAddr = makeAddr("receiver");
        address trigger = makeAddr("trigger");
        IVault.Receiver memory r =
            _makeReceiver(receiverAddr, trigger, address(weth), 1 ether, 1, futureStart, 0, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectRevert(ReceiverNotStartYet.selector);
        vault.payReceiverAmount("alice", 1 ether);
    }

    function test_PayReceiverAmount_revertReceiverProtectionNotEnded() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vault.setNewReceiverProtection(2 days);

        address receiverAddr = makeAddr("receiver");
        address trigger = makeAddr("trigger");
        _addReceiverWithTrigger("alice", receiverAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectRevert(ReceiverProtectionNotEnded.selector);
        vault.payReceiverAmount("alice", 1 ether);
    }

    function test_PayReceiverAmount_revertInsufficientBalance() public {
        _initializeVault();
        address receiverAddr = makeAddr("receiver");
        address trigger = makeAddr("trigger");
        _addReceiverWithTrigger("alice", receiverAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 0.5 ether);

        vm.prank(trigger);
        vm.expectRevert(InsufficientBalance.selector);
        vault.payReceiverAmount("alice", 1 ether);
    }

    function _addReceiver(
        string memory name,
        address receiverAddr,
        uint256 amount,
        uint8 paymentCount,
        uint256 durationTimestamp
    ) internal {
        IVault.Receiver memory r = _makeReceiver(
            receiverAddr, address(0), address(weth), amount, paymentCount, block.timestamp, durationTimestamp, false
        );
        vm.prank(ownerAddress);
        vault.addReceiver(name, r);
    }

    function _addReceiverWithTrigger(
        string memory name,
        address receiverAddr,
        address trigger,
        uint256 amount,
        uint8 paymentCount,
        uint256 durationTimestamp
    ) internal {
        IVault.Receiver memory r = _makeReceiver(
            receiverAddr, trigger, address(weth), amount, paymentCount, block.timestamp, durationTimestamp, false
        );
        vm.prank(ownerAddress);
        vault.addReceiver(name, r);
    }

    function _initializeVault() internal {
        vault.initialize(
            ownerAddress,
            "test vault",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_initialize_storesVaultName() public {
        _initializeVault();
        assertEq(vault.vaultName(), "test vault");
    }

    function test_initialize_emptyNameIsValid() public {
        vault.initialize(
            ownerAddress,
            "",
            assetManagerAddress,
            guardAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        assertEq(vault.vaultName(), "");
    }

    function test_setName_ownerCanUpdate() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vault.setName("renamed vault");
        assertEq(vault.vaultName(), "renamed vault");
    }

    function test_setName_canSetToEmpty() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vault.setName("");
        assertEq(vault.vaultName(), "");
    }

    function test_setName_canUpdateMultipleTimes() public {
        _initializeVault();
        vm.startPrank(ownerAddress);
        vault.setName("first");
        assertEq(vault.vaultName(), "first");
        vault.setName("second");
        assertEq(vault.vaultName(), "second");
        vm.stopPrank();
    }

    function test_setName_revertUnauthorized() public {
        _initializeVault();
        bytes32 _adminRole = vault.DEFAULT_ADMIN_ROLE();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, _adminRole));
        vault.setName("hacked");
    }

    function test_setName_strangerCannotSetName() public {
        _initializeVault();
        bytes32 _adminRole = vault.DEFAULT_ADMIN_ROLE();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, _adminRole));
        vault.setName("attempt");
    }

    function test_setName_doesNotAffectVaultAddress() public {
        _initializeVault();
        address vaultAddr = address(vault);
        vm.prank(ownerAddress);
        vault.setName("new name");
        assertEq(address(vault), vaultAddr, "vault address unchanged after rename");
    }
}
