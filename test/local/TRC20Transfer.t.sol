// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {TRC20Transfer} from "../../src/logic/TRC20Transfer.sol";

/// TRON USDT's `transfer`: moves the tokens, then falls off the end of a `returns (bool)` function.
contract TronUsdtLike is MockERC20("Tether USD", "USDT", 6) {
    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return false;
    }
}

/// Says false and means it.
contract RefusingToken is MockERC20("Refuse", "NO", 6) {
    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// Moves part of the amount and says false: a partial transfer is not a transfer.
contract ShortToken is MockERC20("Short", "SH", 6) {
    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount - 1);
        return false;
    }
}

contract RevertingToken is MockERC20("Revert", "RV", 6) {
    error Nope();

    function transfer(address, uint256) public pure override returns (bool) {
        revert Nope();
    }
}

contract Sender {
    function send(IERC20 token, address to, uint256 value) external {
        TRC20Transfer.safeTransfer(token, to, value);
    }
}

contract TRC20TransferTest is Test {
    Sender sender;
    address to = makeAddr("to");

    function setUp() public {
        sender = new Sender();
    }

    function _fund(MockERC20 t) internal returns (MockERC20) {
        t.mint(address(sender), 100e6);
        return t;
    }

    function test_tronUsdtsFalseOnSuccessIsAccepted() public {
        MockERC20 usdt = _fund(new TronUsdtLike());
        sender.send(IERC20(address(usdt)), to, 40e6);
        assertEq(usdt.balanceOf(to), 40e6);
    }

    /// The failure this library exists to avoid, pinned so a future OpenZeppelin cannot silently fix
    /// or change it under us.
    function test_openZeppelinsSafeTransferRejectsTronUsdt() public {
        MockERC20 usdt = new TronUsdtLike();
        usdt.mint(address(this), 100e6);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdt)));
        this.ozSend(IERC20(address(usdt)), to, 1e6);
    }

    function ozSend(IERC20 token, address recipient, uint256 value) external {
        SafeERC20.safeTransfer(token, recipient, value);
    }

    function test_aStandardTokenStillWorks() public {
        MockERC20 t = _fund(new MockERC20("Std", "STD", 6));
        sender.send(IERC20(address(t)), to, 1e6);
        assertEq(t.balanceOf(to), 1e6);
    }

    function test_falseWithNoMovementReverts() public {
        MockERC20 t = _fund(new RefusingToken());
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t)));
        sender.send(IERC20(address(t)), to, 1e6);
    }

    function test_falseWithAShortMovementReverts() public {
        MockERC20 t = _fund(new ShortToken());
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t)));
        sender.send(IERC20(address(t)), to, 1e6);
    }

    function test_aRevertIsBubbled() public {
        MockERC20 t = _fund(new RevertingToken());
        vm.expectRevert(RevertingToken.Nope.selector);
        sender.send(IERC20(address(t)), to, 1e6);
    }

    function test_noCodeReverts() public {
        address nothing = makeAddr("nothing"); // no code: the balance read already refuses it
        vm.expectRevert();
        sender.send(IERC20(nothing), to, 1e6);
    }
}
