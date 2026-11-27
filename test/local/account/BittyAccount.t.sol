// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {BittyAccount} from "../../../src/account/BittyAccount.sol";
import {BittyAccountFactory} from "../../../src/account/BittyAccountFactory.sol";

contract Token is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// TRON's stake opcodes stand-in: stateless, delegatecalled, so its events come from the account.
/// TRON USDT's quirk: `transfer` returns false when it works, and reverts when it does not.
contract FalseReturningUsdt is ERC20("Tron USDT", "USDT") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return false;
    }
}

contract MockStakeOps {
    event Op(string name, address receiver, uint256 amount, uint256 resource);

    uint256 public immutable releases;

    constructor(uint256 releases_) {
        releases = releases_;
    }

    function freezeBalanceV2(uint256 amount, uint256 resource) external returns (uint256) {
        emit Op("freeze", address(0), amount, resource);
        return 1;
    }

    function unfreezeBalanceV2(uint256 amount, uint256 resource) external returns (uint256) {
        emit Op("unfreeze", address(0), amount, resource);
        return 1;
    }

    function withdrawExpireUnfreeze() external returns (uint256) {
        emit Op("withdraw", address(0), releases, 0);
        return releases;
    }

    function delegateResource(address receiver, uint256 amount, uint256 resource) external returns (uint256) {
        emit Op("delegate", receiver, amount, resource);
        return 1;
    }

    function unDelegateResource(address receiver, uint256 amount, uint256 resource) external returns (uint256) {
        emit Op("undelegate", receiver, amount, resource);
        return 1;
    }
}

contract MockFeed {
    int256 public price = 30_000_000; // $0.30, 8 decimals
    uint256 public updatedAt = block.timestamp;

    function set(int256 p, uint256 at) external {
        price = p;
        updatedAt = at;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, updatedAt, updatedAt, 1);
    }
}

contract MockPermit2 {
    mapping(address owner => mapping(address token => mapping(address spender => uint256))) public allowed;

    function approve(address token, address spender, uint160 amount, uint48) external {
        allowed[msg.sender][token][spender] = amount;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        require(allowed[from][token][msg.sender] >= amount, "permit2 allowance");
        allowed[from][token][msg.sender] -= amount;
        ERC20(token).transferFrom(from, to, amount);
    }
}

/// SunSwap's router stand-in. inputs[0] = abi.encode(fromTrx, amountIn, amountOut, payTo); payTo 0 = the caller.
contract MockRouter {
    MockPermit2 immutable permit2;
    ERC20 immutable usdt;

    constructor(MockPermit2 p, ERC20 u) {
        permit2 = p;
        usdt = u;
    }

    receive() external payable {}

    function execute(bytes calldata, bytes[] calldata inputs, uint256) external payable {
        (bool fromTrx, uint256 amountIn, uint256 amountOut, address payTo) =
            abi.decode(inputs[0], (bool, uint256, uint256, address));
        address to = payTo == address(0) ? msg.sender : payTo;
        if (fromTrx) {
            require(msg.value == amountIn, "value");
            usdt.transfer(to, amountOut);
        } else {
            permit2.transferFrom(msg.sender, address(this), uint160(amountIn), address(usdt));
            payable(to).transfer(amountOut);
        }
    }
}

contract Reverter {
    error Nope();

    function fail() external pure {
        revert Nope();
    }
}

contract BittyAccountTest is Test {
    BittyAccountFactory factory;
    Token usdt;
    Token other;
    uint256 ownerKey = 0xA11CE;
    address owner;
    address relayer = makeAddr("relayer");
    address friend = makeAddr("friend");
    address cold = makeAddr("cold"); // the owner's own cold wallet, a payee
    address thief = makeAddr("thief");
    uint32 constant DAY = 1 days;
    MockFeed feed;
    address feeTo = makeAddr("relayer"); // the relayer is also the swap-fee collector
    MockRouter router;
    MockPermit2 permit2;
    MockStakeOps stakeOps;
    event Op(string name, address receiver, uint256 amount, uint256 resource);

    function setUp() public {
        vm.warp(1_800_000_000);
        owner = vm.addr(ownerKey);
        usdt = new Token();
        other = new Token();
        feed = new MockFeed();
        permit2 = new MockPermit2();
        router = new MockRouter(permit2, usdt);
        stakeOps = new MockStakeOps(7e6);
        usdt.mint(address(router), 1_000_000e6);
        vm.deal(address(router), 10_000_000e6);
        factory = new BittyAccountFactory(
            BittyAccount.Config({
                usdt: address(usdt),
                stakeOps: address(stakeOps),
                router: address(router),
                permit2: address(permit2),
                trxUsdFeed: address(feed),
                feedMaxAge: 1 days,
                feedDecimals: 8,
                usdtFalseIsSuccess: false
            }),
            relayer
        );
        usdt.mint(friend, 1); // an existing holder, as most USDT recipients are
    }

    // ---- helpers

    function _account() internal returns (BittyAccount a) {
        a = BittyAccount(payable(factory.createAccount(owner, 0)));
        usdt.mint(address(a), 1000e6);
    }

    function _send(BittyAccount a, address to, uint256 amount) internal view returns (BittyAccount.Call memory) {
        return BittyAccount.Call(address(a), 0, abi.encodeCall(BittyAccount.sendUsdt, (to, amount)));
    }

    function _one(BittyAccount.Call memory c) internal pure returns (BittyAccount.Call[] memory calls) {
        calls = new BittyAccount.Call[](1);
        calls[0] = c;
    }

    function _self(BittyAccount a, bytes memory data) internal pure returns (BittyAccount.Call memory) {
        return BittyAccount.Call(address(a), 0, data);
    }

    function _sign(BittyAccount a, BittyAccount.Call[] memory calls, uint256 deadline, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, a.executeDigest(calls, a.nonce(), deadline));
        return abi.encodePacked(r, s, v);
    }

    /// Payee `cold`, a 500 USDT daily limit and a 2-day timelock, set up in that order.
    function _protected() internal returns (BittyAccount a) {
        a = _account();
        vm.startPrank(owner);
        a.addPayee(cold); // timelock 0: payable at once
        a.setDailyLimit(500e6, false);
        a.setTimelock(2 * DAY);
        vm.stopPrank();
    }

    /// Queue `calls`, wait out the timelock, run them.
    function _afterTimelock(BittyAccount a, BittyAccount.Call[] memory calls) internal {
        bytes32 id = a.queuedId(calls);
        vm.prank(owner);
        a.queue(id);
        vm.warp(block.timestamp + a.timelock());
        vm.prank(owner);
        a.executeQueued(calls);
    }

    // ---- creation

    function test_addressIsKnownBeforeTheAccountExists() public {
        address predicted = factory.predictAccount(owner, 0);
        assertEq(
            predicted,
            Clones.predictDeterministicAddress(
                factory.implementation(), keccak256(abi.encode(owner, uint256(0))), address(factory)
            )
        );
        usdt.mint(predicted, 10e6);
        BittyAccount a = BittyAccount(payable(factory.createAccount(owner, 0)));
        assertEq(address(a), predicted);
        assertEq(a.owner(), owner);
        assertEq(a.usdt(), address(usdt));
        assertEq(usdt.balanceOf(address(a)), 10e6);
        assertEq(factory.createAccount(owner, 0), address(a), "creating again returns it");
    }

    function test_cannotBeInitializedAgain() public {
        BittyAccount a = _account();
        vm.expectRevert(BittyAccount.AlreadyInitialized.selector);
        a.initialize(thief);
        BittyAccount impl = BittyAccount(payable(factory.implementation()));
        vm.expectRevert(BittyAccount.AlreadyInitialized.selector);
        impl.initialize(thief);
    }

    function test_newAccountHasNoProtection() public {
        BittyAccount a = _account();
        assertEq(a.timelock(), 0);
        (, bool unlimited) = a.dailyLimit();
        assertTrue(unlimited);
        vm.prank(owner);
        a.sendUsdt(friend, 1000e6);
        assertEq(usdt.balanceOf(friend), 1000e6 + 1);
    }

    function test_trxGoesToPayeesOnly() public {
        BittyAccount a = _protected();
        vm.deal(address(a), 100e6);
        vm.startPrank(owner);
        vm.expectRevert(BittyAccount.NotAPayee.selector);
        a.sendTrx(payable(friend), 1e6);
        a.sendTrx(payable(cold), 60e6);
        a.lock();
        a.sendTrx(payable(cold), 40e6); // locked: still to a payee
        vm.stopPrank();
        assertEq(cold.balance, 100e6);
        assertEq(a.leftToday(), 500e6, "TRX is outside the daily limit");
    }

    function test_trxToNonPayeesOnlyByAQueuedCall() public {
        BittyAccount a = _protected();
        vm.deal(address(a), 5e6);
        BittyAccount.Call[] memory out = _one(BittyAccount.Call(friend, 5e6, ""));
        vm.prank(owner);
        vm.expectRevert(BittyAccount.NeedsTimelock.selector);
        a.execute(out);
        _afterTimelock(a, out);
        assertEq(friend.balance, 5e6);
    }

    function test_unprotectedAccountSendsTrxOnlyToPayeesToo() public {
        BittyAccount a = _account();
        vm.deal(address(a), 5e6);
        vm.prank(owner);
        vm.expectRevert(BittyAccount.NotAPayee.selector);
        a.sendTrx(payable(friend), 1e6);
        // with the timelock at 0, a plain call is not held back
        vm.prank(owner);
        a.execute(_one(BittyAccount.Call(friend, 1e6, "")));
        assertEq(friend.balance, 1e6);
    }

    // ---- daily limit

    function test_dailyLimitHoldsSendsToNonPayees() public {
        BittyAccount a = _protected();
        vm.startPrank(owner);
        a.sendUsdt(friend, 300e6);
        a.sendUsdt(friend, 200e6);
        vm.expectRevert(abi.encodeWithSelector(BittyAccount.OverDailyLimit.selector, 0));
        a.sendUsdt(friend, 1);
        vm.stopPrank();
        assertEq(a.leftToday(), 0);
        vm.warp(block.timestamp + DAY);
        assertEq(a.leftToday(), 500e6, "a new UTC day");
        vm.prank(owner);
        a.sendUsdt(friend, 500e6);
    }

    function test_payeesAreNotLimited() public {
        BittyAccount a = _protected();
        vm.prank(owner);
        a.sendUsdt(cold, 1000e6);
        assertEq(usdt.balanceOf(cold), 1000e6);
        assertEq(a.leftToday(), 500e6);
    }

    function test_limitLowersAtOnceAndRisesOnlyAfterTheTimelock() public {
        BittyAccount a = _protected();
        vm.startPrank(owner);
        a.setDailyLimit(100e6, false);
        vm.expectRevert(BittyAccount.NeedsTimelock.selector);
        a.setDailyLimit(1000e6, false);
        vm.expectRevert(BittyAccount.NeedsTimelock.selector);
        a.setDailyLimit(0, true);
        vm.stopPrank();
        _afterTimelock(a, _one(_self(a, abi.encodeCall(BittyAccount.setDailyLimit, (1000e6, false)))));
        (uint256 limit,) = a.dailyLimit();
        assertEq(limit, 1000e6);
    }

    // ---- payees

    function test_payeeWaitsOutTheTimelock() public {
        BittyAccount a = _protected();
        vm.prank(owner);
        a.addPayee(friend);
        assertFalse(a.isPayee(friend));
        vm.warp(block.timestamp + 2 * DAY);
        assertTrue(a.isPayee(friend));
    }

    function test_removingAPayableOneWaitsAndAPendingOneGoesAtOnce() public {
        BittyAccount a = _protected();
        vm.startPrank(owner);
        a.removePayee(cold);
        assertTrue(a.isPayee(cold), "still payable during the timelock");
        a.addPayee(friend);
        a.removePayee(friend);
        vm.stopPrank();
        assertEq(a.payee(friend).readyAt, 0, "a pending payee goes at once");
        vm.warp(block.timestamp + 2 * DAY);
        assertFalse(a.isPayee(cold));
    }

    // ---- lock

    function test_lockedAccountPaysOnlyPayees() public {
        BittyAccount a = _protected();
        vm.startPrank(owner);
        a.lock();
        vm.expectRevert(BittyAccount.AccountLocked.selector);
        a.sendUsdt(friend, 1);
        a.sendUsdt(cold, 1000e6);
        vm.stopPrank();
        assertEq(usdt.balanceOf(cold), 1000e6);
    }

    function test_lockCancelsEverythingWaiting() public {
        BittyAccount a = _protected();
        BittyAccount.Call[] memory drain =
            _one(BittyAccount.Call(address(usdt), 0, abi.encodeCall(ERC20.transfer, (thief, 1000e6))));
        // a thief with the key: adds a payee, queues a removal of the owner's, queues a drain
        bytes32 drainId = a.queuedId(drain);
        vm.startPrank(owner);
        a.addPayee(thief);
        a.removePayee(cold);
        a.queue(drainId);
        vm.stopPrank();
        // the owner locks before any of it comes due
        vm.warp(block.timestamp + DAY);
        vm.prank(owner);
        a.lock();
        vm.warp(block.timestamp + 10 * DAY);
        assertFalse(a.isPayee(thief), "the thief's payee never matures");
        assertTrue(a.isPayee(cold), "the removal of the owner's payee was cancelled");
        // even unlocked again, the cancelled things stay cancelled
        vm.startPrank(owner);
        a.requestUnlock();
        vm.warp(block.timestamp + 2 * DAY);
        a.unlock();
        vm.expectRevert(BittyAccount.NotReady.selector);
        a.executeQueued(drain);
        vm.stopPrank();
        assertFalse(a.isPayee(thief));
        assertTrue(a.isPayee(cold));
    }

    function test_lockKeepsWhatWasAlreadyDue() public {
        BittyAccount a = _protected();
        vm.prank(owner);
        a.addPayee(friend);
        vm.warp(block.timestamp + 2 * DAY); // friend matures
        vm.prank(owner);
        a.lock();
        assertTrue(a.isPayee(friend));
        vm.prank(owner);
        a.sendUsdt(friend, 10e6);
    }

    function test_unlockWaitsAndLockingAgainCancelsIt() public {
        BittyAccount a = _protected();
        vm.startPrank(owner);
        a.lock();
        vm.expectRevert(BittyAccount.NotReady.selector);
        a.unlock();
        a.requestUnlock();
        vm.warp(block.timestamp + DAY);
        a.lock(); // the owner sees a thief's unlock request and locks again
        vm.warp(block.timestamp + 2 * DAY);
        vm.expectRevert(BittyAccount.NotReady.selector);
        a.unlock();
        a.requestUnlock();
        vm.warp(block.timestamp + 2 * DAY);
        a.unlock();
        vm.stopPrank();
        assertFalse(a.locked());
    }

    function test_lockedAccountTakesNoNewPayeeOrQueue() public {
        BittyAccount a = _protected();
        vm.startPrank(owner);
        a.lock();
        vm.expectRevert(BittyAccount.AccountLocked.selector);
        a.addPayee(friend);
        vm.expectRevert(BittyAccount.AccountLocked.selector);
        a.removePayee(cold);
        vm.expectRevert(BittyAccount.AccountLocked.selector);
        a.queue(bytes32(uint256(1)));
        vm.stopPrank();
    }

    // ---- other calls

    function test_otherCallsNeedTheTimelock() public {
        BittyAccount a = _protected();
        BittyAccount.Call[] memory approve =
            _one(BittyAccount.Call(address(usdt), 0, abi.encodeCall(ERC20.approve, (thief, type(uint256).max))));
        vm.prank(owner);
        vm.expectRevert(BittyAccount.NeedsTimelock.selector);
        a.execute(approve);
        _afterTimelock(a, approve);
        assertEq(usdt.allowance(address(a), thief), type(uint256).max);
    }

    function test_otherTokensLeaveOnlyByAQueuedCall() public {
        BittyAccount a = _protected();
        other.mint(address(a), 5e6);
        BittyAccount.Call[] memory out =
            _one(BittyAccount.Call(address(other), 0, abi.encodeCall(ERC20.transfer, (cold, 5e6))));
        vm.prank(owner);
        vm.expectRevert(BittyAccount.NeedsTimelock.selector);
        a.execute(out);
        _afterTimelock(a, out);
        assertEq(other.balanceOf(cold), 5e6);
    }

    function test_queuedCallWaitsItsFullTimelock() public {
        BittyAccount a = _protected();
        BittyAccount.Call[] memory calls = _one(_self(a, abi.encodeCall(BittyAccount.setTimelock, (0))));
        bytes32 id = a.queuedId(calls);
        vm.prank(owner);
        a.queue(id);
        vm.warp(block.timestamp + 2 * DAY - 1);
        vm.prank(owner);
        vm.expectRevert(BittyAccount.NotReady.selector);
        a.executeQueued(calls);
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        a.executeQueued(calls);
        assertEq(a.timelock(), 0);
        vm.prank(owner);
        vm.expectRevert(BittyAccount.NotReady.selector);
        a.executeQueued(calls); // used once
    }

    function test_aFailingCallUndoesTheBatch() public {
        BittyAccount a = _account();
        Reverter r = new Reverter();
        BittyAccount.Call[] memory calls = new BittyAccount.Call[](2);
        calls[0] = _send(a, friend, 4e6);
        calls[1] = BittyAccount.Call(address(r), 0, abi.encodeCall(Reverter.fail, ()));
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BittyAccount.CallFailed.selector, 1, abi.encodeWithSelector(Reverter.Nope.selector))
        );
        a.execute(calls);
        assertEq(usdt.balanceOf(address(a)), 1000e6);
    }

    // ---- the key

    function test_newKeyNeedsTheTimelock() public {
        BittyAccount a = _protected();
        address newKey = makeAddr("newKey");
        vm.prank(owner);
        vm.expectRevert(BittyAccount.NeedsTimelock.selector);
        a.proposeOwner(newKey);
        _afterTimelock(a, _one(_self(a, abi.encodeCall(BittyAccount.proposeOwner, (newKey)))));
        vm.prank(newKey);
        a.acceptOwner();
        assertEq(a.owner(), newKey);
        vm.prank(owner);
        vm.expectRevert(BittyAccount.NotOwner.selector);
        a.sendUsdt(owner, 1);
    }

    function test_onlyTheOwnerActs() public {
        BittyAccount a = _account();
        vm.startPrank(thief);
        vm.expectRevert(BittyAccount.NotOwner.selector);
        a.sendUsdt(thief, 1);
        vm.expectRevert(BittyAccount.NotOwner.selector);
        a.execute(_one(_send(a, thief, 1)));
        vm.expectRevert(BittyAccount.NotOwner.selector);
        a.lock();
        vm.stopPrank();
    }

    // ---- signed, sent by a relayer

    function test_relayerSendsWhatTheOwnerSignedAndIsPaidInTheBatch() public {
        BittyAccount a = _protected();
        BittyAccount.Call[] memory calls = new BittyAccount.Call[](2);
        calls[0] = _send(a, friend, 4e6);
        calls[1] = _send(a, relayer, 1e6); // the relayer's fee: its own cap, not the daily limit
        bytes memory sig = _sign(a, calls, block.timestamp + 60, ownerKey);
        vm.prank(relayer);
        a.executeSigned(calls, block.timestamp + 60, sig);
        assertEq(usdt.balanceOf(friend), 4e6 + 1);
        assertEq(usdt.balanceOf(relayer), 1e6);
        assertEq(a.leftToday(), 496e6);
        assertEq(owner.balance, 0, "the owner key never needed TRX");
    }

    function test_signedBatchWorksOnceOnItsAccountAndExpires() public {
        BittyAccount a = _account();
        BittyAccount b = BittyAccount(payable(factory.createAccount(owner, 1)));
        usdt.mint(address(b), 10e6);
        BittyAccount.Call[] memory calls = _one(_send(a, friend, 1e6));
        uint256 deadline = block.timestamp + 60;
        bytes memory sig = _sign(a, calls, deadline, ownerKey);
        vm.expectRevert(BittyAccount.BadSignature.selector);
        b.executeSigned(_one(_send(b, friend, 1e6)), deadline, sig);
        a.executeSigned(calls, deadline, sig);
        vm.expectRevert(BittyAccount.BadSignature.selector);
        a.executeSigned(calls, deadline, sig);
        bytes memory late = _sign(a, calls, deadline, ownerKey);
        vm.warp(deadline + 1);
        vm.expectRevert(BittyAccount.Expired.selector);
        a.executeSigned(calls, deadline, late);
        // (block.timestamp is read once under via-ir, so the new deadline is spelled out)
        uint256 later = deadline + 120;
        bytes memory wrongKey = _sign(a, calls, later, 0xB0B);
        vm.expectRevert(BittyAccount.BadSignature.selector);
        a.executeSigned(calls, later, wrongKey);
    }

    function test_firstSendCreatesTheAccountInTheSameTransaction() public {
        address predicted = factory.predictAccount(owner, 0);
        usdt.mint(predicted, 10e6);
        BittyAccount.Call[] memory calls = new BittyAccount.Call[](2);
        calls[0] = BittyAccount.Call(predicted, 0, abi.encodeCall(BittyAccount.sendUsdt, (friend, 4e6)));
        calls[1] = BittyAccount.Call(predicted, 0, abi.encodeCall(BittyAccount.sendUsdt, (relayer, 1e6)));
        uint256 deadline = block.timestamp + 60;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digestFor(predicted, calls, 0, deadline));
        vm.prank(relayer);
        (address account,) = factory.createAndExecute(owner, 0, calls, deadline, abi.encodePacked(r, s, v));
        assertEq(account, predicted);
        assertEq(usdt.balanceOf(friend), 4e6 + 1);
        assertEq(usdt.balanceOf(relayer), 1e6);
    }

    function test_createAndExecuteNeedsTheOwnersSignature() public {
        address predicted = factory.predictAccount(owner, 0);
        BittyAccount.Call[] memory calls =
            _one(BittyAccount.Call(predicted, 0, abi.encodeCall(BittyAccount.sendUsdt, (relayer, 1))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, _digestFor(predicted, calls, 0, block.timestamp + 60));
        vm.expectRevert(BittyAccount.BadSignature.selector);
        factory.createAndExecute(owner, 0, calls, block.timestamp + 60, abi.encodePacked(r, s, v));
    }

    /// The EIP-712 digest for an account that may not exist yet, built as the app would.
    function _digestFor(address account, BittyAccount.Call[] memory calls, uint256 n, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            hashes[i] = keccak256(
                abi.encode(
                    keccak256("Call(address to,uint256 value,bytes data)"),
                    calls[i].to,
                    calls[i].value,
                    keccak256(calls[i].data)
                )
            );
        }
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Execute(Call[] calls,uint256 nonce,uint256 deadline)Call(address to,uint256 value,bytes data)"
                ),
                keccak256(abi.encodePacked(hashes)),
                n,
                deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Bitty Account"),
                keccak256("1"),
                block.chainid,
                account
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    // ---- TRON USDT returning false

    function _factoryFor(address token, bool falseIsSuccess) internal returns (BittyAccountFactory) {
        return new BittyAccountFactory(
            BittyAccount.Config({
                usdt: token,
                stakeOps: address(stakeOps),
                router: address(router),
                permit2: address(permit2),
                trxUsdFeed: address(feed),
                feedMaxAge: 1 days,
                feedDecimals: 8,
                usdtFalseIsSuccess: falseIsSuccess
            }),
            relayer
        );
    }

    function test_tronUsdtFalseCountsAsSuccessWhenTheFactorySaysSo() public {
        FalseReturningUsdt tusdt = new FalseReturningUsdt();
        BittyAccount a = BittyAccount(payable(_factoryFor(address(tusdt), true).createAccount(owner, 0)));
        tusdt.mint(address(a), 10e6);
        vm.prank(owner);
        a.sendUsdt(friend, 4e6);
        assertEq(tusdt.balanceOf(friend), 4e6);
        vm.prank(owner);
        vm.expectRevert(); // a real failure still reverts inside the token
        a.sendUsdt(friend, 7e6);
    }

    function test_falseIsAFailureOtherwise() public {
        FalseReturningUsdt tusdt = new FalseReturningUsdt();
        BittyAccount a = BittyAccount(payable(_factoryFor(address(tusdt), false).createAccount(owner, 0)));
        tusdt.mint(address(a), 10e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BittyAccount.UsdtTransferFailed.selector, abi.encode(false)));
        a.sendUsdt(friend, 4e6);
    }

    // ---- the relayer's fee

    function test_relayerIsPaidLockedOverTheLimitAndNotAPayee() public {
        BittyAccount a = _protected();
        vm.startPrank(owner);
        a.sendUsdt(friend, 500e6); // the daily limit used up
        a.lock();
        a.sendUsdt(relayer, 2e6);
        vm.stopPrank();
        assertEq(usdt.balanceOf(relayer), 2e6);
        assertEq(a.leftToday(), 0);
        assertEq(a.relayerPaidToday(), 2e6);
    }

    function test_relayerCapPerDay() public {
        BittyAccount a = _protected();
        usdt.mint(address(a), 5_000e6);
        vm.startPrank(owner);
        a.sendUsdt(relayer, 999e6);
        vm.expectRevert(abi.encodeWithSelector(BittyAccount.OverRelayerCap.selector, 1e6));
        a.sendUsdt(relayer, 2e6);
        a.sendUsdt(relayer, 1e6);
        vm.warp(block.timestamp + DAY);
        a.sendUsdt(relayer, 1_000e6); // a new UTC day
        vm.stopPrank();
        assertEq(usdt.balanceOf(relayer), 2_000e6);
    }

    function test_unprotectedSendsDoNotAskForTheRelayer() public {
        BittyAccount a = _account();
        vm.prank(owner);
        a.sendUsdt(relayer, 1e6); // no lock, no limit: an ordinary send, nothing counted
        assertEq(a.relayerPaidToday(), 0);
    }

    function test_theFactoryOwnerChangesTheRelayer() public {
        BittyAccount a = _protected();
        address next = makeAddr("next relayer");
        vm.prank(thief);
        vm.expectRevert(BittyAccountFactory.NotOwner.selector);
        factory.setRelayer(next);
        factory.setRelayer(next); // this test deployed the factory, so it is the owner
        assertEq(a.relayer(), next);
        vm.startPrank(owner);
        a.lock();
        vm.expectRevert(BittyAccount.AccountLocked.selector);
        a.sendUsdt(relayer, 1e6); // the old relayer is an ordinary address now
        a.sendUsdt(next, 1e6);
        vm.stopPrank();
        assertEq(usdt.balanceOf(next), 1e6);
    }

    function test_factoryOwnershipIsTwoStep() public {
        address next = makeAddr("next owner");
        factory.transferOwnership(next);
        assertEq(factory.owner(), address(this));
        vm.prank(thief);
        vm.expectRevert(BittyAccountFactory.NotPendingOwner.selector);
        factory.acceptOwnership();
        vm.prank(next);
        factory.acceptOwnership();
        assertEq(factory.owner(), next);
        vm.expectRevert(BittyAccountFactory.NotOwner.selector);
        factory.setRelayer(next);
    }

    // ---- staking

    function test_stakeUnstakeWithdraw() public {
        BittyAccount a = _protected();
        vm.startPrank(owner);
        vm.expectEmit(address(a));
        emit Op("freeze", address(0), 100e6, 1);
        a.stakeTrx(100e6);
        vm.expectEmit(address(a));
        emit Op("unfreeze", address(0), 40e6, 1);
        a.unstakeTrx(40e6);
        assertEq(a.withdrawUnstaked(), 7e6);
        vm.stopPrank();
    }

    function test_stakingWorksWhileLocked() public {
        BittyAccount a = _protected();
        vm.startPrank(owner);
        a.lock();
        a.stakeTrx(1e6);
        a.unstakeTrx(1e6);
        a.withdrawUnstaked();
        a.delegateEnergy(cold, 1e6); // to a payee
        a.undelegateEnergy(cold, 1e6);
        vm.stopPrank();
    }

    function test_energyGoesToTheOwnerOrAPayeeAtOnceAndElsewhereAfterTheTimelock() public {
        BittyAccount a = _protected();
        vm.startPrank(owner);
        a.delegateEnergy(owner, 10e6);
        a.delegateEnergy(cold, 10e6);
        vm.expectRevert(BittyAccount.NeedsTimelock.selector);
        a.delegateEnergy(relayer, 10e6);
        a.lock();
        vm.expectRevert(BittyAccount.AccountLocked.selector);
        a.delegateEnergy(relayer, 10e6);
        a.requestUnlock();
        vm.warp(block.timestamp + 2 * DAY);
        a.unlock();
        vm.stopPrank();
        BittyAccount.Call[] memory calls = _one(_self(a, abi.encodeCall(BittyAccount.delegateEnergy, (relayer, 10e6))));
        bytes32 id = a.queuedId(calls);
        vm.prank(owner);
        a.queue(id);
        vm.warp(block.timestamp + 2 * DAY);
        vm.expectEmit(address(a));
        emit Op("delegate", relayer, 10e6, 1);
        vm.prank(owner);
        a.executeQueued(calls);
    }

    function test_onlyTheOwnerStakes() public {
        BittyAccount a = _account();
        vm.startPrank(thief);
        vm.expectRevert(BittyAccount.NotOwner.selector);
        a.stakeTrx(1);
        vm.expectRevert(BittyAccount.NotOwner.selector);
        a.delegateEnergy(thief, 1);
        vm.stopPrank();
    }

    // ---- swaps

    function _route(bool fromTrx, uint256 amountIn, uint256 amountOut, address payTo)
        internal
        view
        returns (bytes memory)
    {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(fromTrx, amountIn, amountOut, payTo);
        return abi.encodePacked(
            bytes4(keccak256("bitty.uniswap.universal-route")), abi.encode(hex"00", inputs, block.timestamp)
        );
    }

    function test_swapTrxForUsdtAtTheFeedPriceCostsNoLimit() public {
        BittyAccount a = _protected();
        vm.deal(address(a), 1000e6);
        vm.prank(owner);
        uint256 got = a.swapTrxForUsdt(1000e6, 299e6, _route(true, 998e6, 299.4e6, address(0)));
        assertEq(got, 299.4e6);
        assertEq(address(a).balance, 0);
        assertEq(feeTo.balance, 2e6, "0.2% of the TRX sold");
        assertEq(usdt.balanceOf(address(a)), 1299.4e6);
        assertEq(a.leftToday(), 500e6, "at the feed price nothing is lost");
    }

    function test_swapUsdtForTrx() public {
        BittyAccount a = _protected();
        vm.prank(owner);
        uint256 got = a.swapUsdtForTrx(30e6, 99e6, _route(false, 30e6, 100e6, address(0)));
        assertEq(got, 99.8e6);
        assertEq(address(a).balance, 99.8e6);
        assertEq(feeTo.balance, 0.2e6, "0.2% of the TRX bought");
        assertEq(usdt.balanceOf(address(a)), 970e6);
        assertEq(permit2.allowed(address(a), address(usdt), address(router)), 0, "nothing left for the router");
    }

    function test_theFeeIsNotCountedAsALoss() public {
        BittyAccount a = _protected();
        vm.prank(owner);
        a.swapUsdtForTrx(30e6, 0, _route(false, 30e6, 100e6, address(0))); // at the feed price
        assertEq(a.leftToday(), 500e6);
        assertEq(feeTo.balance, 0.2e6);
    }

    function test_aBadPriceCountsTowardTheDailyLimit() public {
        BittyAccount a = _protected();
        // 100 USDT for 200 TRX worth $60: $40 below the feed
        vm.prank(owner);
        a.swapUsdtForTrx(100e6, 0, _route(false, 100e6, 200e6, address(0)));
        assertEq(a.leftToday(), 460e6);
    }

    function test_aThiefsSwapLosesNoMoreThanTheLimit() public {
        BittyAccount a = _protected();
        // the route sends the output to the thief: all 600 USDT count as lost, over the 500 limit
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BittyAccount.OverDailyLimit.selector, 500e6));
        a.swapUsdtForTrx(600e6, 0, _route(false, 600e6, 2000e6, thief));
        // within the limit it goes through, and uses the limit up
        vm.prank(owner);
        a.swapUsdtForTrx(500e6, 0, _route(false, 500e6, 2000e6, thief));
        assertEq(a.leftToday(), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BittyAccount.OverDailyLimit.selector, 0));
        a.sendUsdt(friend, 1);
    }

    function test_swapChecksMinimumOutput() public {
        BittyAccount a = _protected();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BittyAccount.InsufficientOutput.selector, 89.82e6));
        a.swapUsdtForTrx(30e6, 100e6, _route(false, 30e6, 90e6, address(0)));
    }

    function test_noSwapWhileLockedOrWithAStalePrice() public {
        BittyAccount a = _protected();
        bytes memory route = _route(false, 30e6, 100e6, address(0));
        feed.set(30_000_000, block.timestamp - 1 days - 1);
        vm.prank(owner);
        vm.expectRevert(BittyAccount.PriceStale.selector);
        a.swapUsdtForTrx(30e6, 0, route);
        vm.startPrank(owner);
        a.lock();
        vm.expectRevert(BittyAccount.AccountLocked.selector);
        a.swapUsdtForTrx(30e6, 0, route);
        vm.stopPrank();
    }

    function test_unprotectedAccountSwapsWithoutReadingThePrice() public {
        BittyAccount a = _account();
        feed.set(0, 0); // a broken feed does not matter without a limit
        vm.prank(owner);
        a.swapUsdtForTrx(30e6, 99.8e6, _route(false, 30e6, 100e6, address(0)));
        assertEq(address(a).balance, 99.8e6);
    }

    function test_swapRejectsANonRoute() public {
        BittyAccount a = _account();
        vm.prank(owner);
        vm.expectRevert(BittyAccount.NotARoute.selector);
        a.swapUsdtForTrx(1, 0, hex"deadbeef");
    }

    // ---- cost: EVM gas with every account and slot cold, no 21000 base or calldata (TRON charges
    //      those as bandwidth, not energy)

    function _cool(BittyAccount a) internal {
        vm.cool(address(router));
        vm.cool(address(permit2));
        vm.cool(address(feed));
        vm.cool(address(stakeOps));
        vm.cool(address(a));
        vm.cool(address(usdt));
        vm.cool(factory.implementation());
        vm.cool(friend);
        vm.cool(cold);
    }

    function _measure(BittyAccount a, string memory label, bytes memory data) internal returns (uint256 used) {
        _cool(a);
        vm.prank(owner);
        uint256 g = gasleft();
        (bool ok,) = address(a).call(data);
        used = g - gasleft();
        require(ok, label);
        console.log(label, used);
    }

    function test_gas() public {
        vm.cool(address(factory));
        uint256 g = gasleft();
        BittyAccount a = BittyAccount(payable(factory.createAccount(owner, 0)));
        console.log("create account                      ", g - gasleft());
        usdt.mint(address(a), 10_000e6);
        address holder = makeAddr("holder");
        usdt.mint(holder, 100e6);

        _cool(a);
        vm.prank(holder);
        g = gasleft();
        usdt.transfer(friend, 1e6);
        console.log("USDT transfer, normal account       ", g - gasleft());

        bytes memory toFriend = abi.encodeCall(BittyAccount.sendUsdt, (friend, 1e6));
        _measure(a, "sendUsdt, no protection             ", toFriend);

        _measure(a, "add payee (timelock 0)              ", abi.encodeCall(BittyAccount.addPayee, (cold)));
        _measure(a, "set daily limit                     ", abi.encodeCall(BittyAccount.setDailyLimit, (500e6, false)));
        _measure(a, "set timelock                        ", abi.encodeCall(BittyAccount.setTimelock, (2 * DAY)));
        _measure(a, "add payee (timelock 2 days)         ", abi.encodeCall(BittyAccount.addPayee, (friend)));

        vm.warp(block.timestamp + DAY); // a new day: the limit's first send of it
        _measure(a, "sendUsdt, limited, first of the day ", toFriend);
        _measure(a, "sendUsdt, limited, again same day   ", toFriend);
        _measure(a, "sendUsdt to a payee                 ", abi.encodeCall(BittyAccount.sendUsdt, (cold, 1e6)));

        bytes32 id = keccak256("x");
        _measure(a, "queue a call                        ", abi.encodeCall(BittyAccount.queue, (id)));
        _measure(a, "lock                                ", abi.encodeCall(BittyAccount.lock, ()));
        _measure(a, "sendUsdt to a payee, locked         ", abi.encodeCall(BittyAccount.sendUsdt, (cold, 1e6)));
        vm.deal(address(a), 100e6);
        vm.deal(cold, 1);
        _measure(a, "stake TRX                           ", abi.encodeCall(BittyAccount.stakeTrx, (10e6)));
        _measure(a, "delegate energy to the owner        ", abi.encodeCall(BittyAccount.delegateEnergy, (owner, 10e6)));
        _measure(a, "sendTrx to a payee, locked          ", abi.encodeCall(BittyAccount.sendTrx, (payable(cold), 1e6)));
        _measure(a, "request unlock                      ", abi.encodeCall(BittyAccount.requestUnlock, ()));
        vm.warp(block.timestamp + 2 * DAY);
        _measure(a, "unlock                              ", abi.encodeCall(BittyAccount.unlock, ()));
        feed.set(30_000_000, block.timestamp);
        _measure(
            a,
            "swap USDT->TRX, first (approve)     ",
            abi.encodeCall(BittyAccount.swapUsdtForTrx, (30e6, 0, _route(false, 30e6, 100e6, address(0))))
        );
        _measure(
            a,
            "swap USDT->TRX, again               ",
            abi.encodeCall(BittyAccount.swapUsdtForTrx, (30e6, 0, _route(false, 30e6, 100e6, address(0))))
        );
        _measure(
            a,
            "swap TRX->USDT                      ",
            abi.encodeCall(BittyAccount.swapTrxForUsdt, (100e6, 0, _route(true, 99.8e6, 30e6, address(0))))
        );

        // relayed, through execute: the same send plus the batch around it
        BittyAccount.Call[] memory calls = new BittyAccount.Call[](2);
        calls[0] = _send(a, friend, 1e6);
        calls[1] = _send(a, relayer, 1e6);
        usdt.mint(relayer, 1);
        uint256 deadline = block.timestamp + 60;
        bytes memory sig = _sign(a, calls, deadline, ownerKey);
        _cool(a);
        vm.cool(relayer);
        vm.prank(relayer);
        g = gasleft();
        a.executeSigned(calls, deadline, sig);
        console.log("relayed: send + USDT fee, limited   ", g - gasleft());
        console.log(
            "calldata bytes, relayed send + fee  ",
            abi.encodeCall(BittyAccount.executeSigned, (calls, deadline, sig)).length
        );
    }

    function test_gasFirstRelayedSend() public {
        address predicted = factory.predictAccount(owner, 0);
        usdt.mint(predicted, 100e6);
        usdt.mint(relayer, 1);
        BittyAccount.Call[] memory calls = new BittyAccount.Call[](2);
        calls[0] = BittyAccount.Call(predicted, 0, abi.encodeCall(BittyAccount.sendUsdt, (friend, 1e6)));
        calls[1] = BittyAccount.Call(predicted, 0, abi.encodeCall(BittyAccount.sendUsdt, (relayer, 1e6)));
        uint256 deadline = block.timestamp + 60;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digestFor(predicted, calls, 0, deadline));
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.cool(address(factory));
        vm.cool(address(usdt));
        vm.cool(factory.implementation());
        vm.cool(friend);
        vm.cool(relayer);
        vm.prank(relayer);
        uint256 g = gasleft();
        factory.createAndExecute(owner, 0, calls, deadline, sig);
        console.log("first relayed send (create+send+fee)", g - gasleft());
    }
}
