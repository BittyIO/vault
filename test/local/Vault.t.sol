// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {
    IVault,
    AddressZero,
    AmountIsZero,
    ReceiverNotFound,
    ReceiverImmutable,
    ReceiverPaymentCountZero,
    ReceiverDurationTimestampNotSet,
    OnlyReceiver,
    ReceiverNotStartYet
} from "../../src/interfaces/IVault.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {WhiteList} from "whitelist-contracts/src/WhiteList.sol";

contract VaultTest is Test {
    Vault public vault;
    WETH public weth;
    address public whiteListAddress;
    address public ownerAddress;

    function setUp() public {
        weth = new WETH();
        vault = new Vault();
        whiteListAddress = address(new WhiteList());
        ownerAddress = tx.origin;
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
            lastReceiveTimestamp: 0,
            isImmutable: isImmutable_
        });
    }

    function test_InitErrorWithWethAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        vault.initialize(
            address(whiteListAddress),
            address(0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_InitErrorWithAlreadyInitialized() public {
        vault.initialize(
            address(whiteListAddress),
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        vm.expectRevert("Initializable: contract is already initialized");
        vault.initialize(
            address(whiteListAddress),
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_GetVaultInitCode() public pure {
        bytes memory bytecode = type(Vault).creationCode;
        console.logBytes32(keccak256(bytecode));
    }

    function test_AddReceiverSuccess() public {
        vault.initialize(
            whiteListAddress,
            address(weth),
            new address[](0),
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

    function test_AddReceiverRevertOnlyOwner() public {
        vault.initialize(
            whiteListAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Ownable: caller is not the owner");
        vault.addReceiver("alice", r);
    }

    function test_AddReceiverRevertAmountZero() public {
        vault.initialize(
            whiteListAddress,
            address(weth),
            new address[](0),
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
            whiteListAddress,
            address(weth),
            new address[](0),
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

    function test_AddReceiverRevertDurationTimestampNotSet() public {
        vault.initialize(
            whiteListAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        IVault.Receiver memory r =
            _makeReceiver(makeAddr("receiver"), address(0), address(weth), 1 ether, 2, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        vm.expectRevert(ReceiverDurationTimestampNotSet.selector);
        vault.addReceiver("alice", r);
    }

    function test_UpdateReceiverRevertDurationTimestampNotSet() public {
        vault.initialize(
            whiteListAddress,
            address(weth),
            new address[](0),
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

        r.paymentCount = 3;
        r.durationTimestamp = 0;
        vm.prank(ownerAddress);
        vm.expectRevert(ReceiverDurationTimestampNotSet.selector);
        vault.updateReceiver("alice", r);
    }

    function test_UpdateReceiverSuccess() public {
        vault.initialize(
            whiteListAddress,
            address(weth),
            new address[](0),
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
            whiteListAddress,
            address(weth),
            new address[](0),
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
            whiteListAddress,
            address(weth),
            new address[](0),
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
            whiteListAddress,
            address(weth),
            new address[](0),
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
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Ownable: caller is not the owner");
        vault.updateReceiver("alice", r);
    }

    function test_RemoveReceiverSuccess() public {
        vault.initialize(
            whiteListAddress,
            address(weth),
            new address[](0),
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
            whiteListAddress,
            address(weth),
            new address[](0),
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
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Ownable: caller is not the owner");
        vault.removeReceiver("alice");
    }

    function test_ChangeReceiverAddressSuccess() public {
        vault.initialize(
            whiteListAddress,
            address(weth),
            new address[](0),
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
            whiteListAddress,
            address(weth),
            new address[](0),
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
            whiteListAddress,
            address(weth),
            new address[](0),
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
            whiteListAddress,
            address(weth),
            new address[](0),
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
            whiteListAddress,
            address(weth),
            new address[](0),
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

    function test_PayReceiver_receiverStorageUpdatedSoPaymentCountEnforced() public {
        vault.initialize(
            whiteListAddress,
            address(weth),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        address receiverAddr = makeAddr("receiver");
        vm.warp(1000);
        uint256 duration = 100;
        IVault.Receiver memory r =
            _makeReceiver(receiverAddr, address(0), address(weth), 1 ether, 2, block.timestamp, duration, false);
        vm.prank(ownerAddress);
        vault.addReceiver("alice", r);

        deal(address(weth), address(vault), 2 ether);

        vault.payReceiver("alice");
        vm.warp(block.timestamp + duration);
        vault.payReceiver("alice");

        assertEq(weth.balanceOf(receiverAddr), 2 ether, "receiver should have received 2 payments");

        vm.expectRevert(ReceiverPaymentCountZero.selector);
        vault.payReceiver("alice");
    }
}
